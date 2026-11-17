#!/usr/bin/env bash
#######################################
# Pod VM Image Scan Script
#######################################
#
# Scans a built pod VM disk image for vulnerabilities and secrets, and writes
# SARIF for GitHub code scanning alongside a human-readable summary.
#
# trivy cannot read a raw disk directly -- `trivy vm` handles VMDK and live
# AMIs, not a local .raw -- so this mounts the image's root filesystem
# read-only on a loop device and runs `trivy rootfs` against the mount.
#
# Needs Linux and root (losetup + mount).
#
# Usage:
#   ./scan-image.sh --image PATH [options]
#
# Options:
#   -i, --image PATH      Disk image to scan (.raw)
#   -s, --severity LIST   Severities that fail the scan (default: HIGH,CRITICAL)
#       --sarif PATH      Where to write SARIF (default: alongside the image)
#       --json PATH       Where to write the raw JSON result
#       --sbom PATH       Where to write a CycloneDX SBOM
#       --ignore-unfixed  Do not gate on findings that have no fix yet
#   -h, --help            Show this help message
#
# Examples:
#   # Scan a build and fail on fixable HIGH/CRITICAL
#   ./scan-image.sh --image build/podvm-v0.23.0-x86_64.raw
#######################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

IMAGE=""
SEVERITY="HIGH,CRITICAL"
SARIF_OUT=""
JSON_OUT=""
SBOM_OUT=""
# Empty means every finding at $SEVERITY gates, fix available or not. An
# unfixed CRITICAL is still a CRITICAL in the shipped image.
IGNORE_UNFIXED=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)        need_value "$@"; IMAGE="$2"; shift 2 ;;
    -s|--severity)     need_value "$@"; SEVERITY="$2"; shift 2 ;;
    --sarif)           need_value "$@"; SARIF_OUT="$2"; shift 2 ;;
    --json)            need_value "$@"; JSON_OUT="$2"; shift 2 ;;
    --sbom)            need_value "$@"; SBOM_OUT="$2"; shift 2 ;;
    --ignore-unfixed)  IGNORE_UNFIXED="yes"; shift ;;
    -h|--help)         print_help "${BASH_SOURCE[0]}"; exit 0 ;;
    *)                 error "Unknown option: $1 (try --help)" ;;
  esac
done

[[ -n "$IMAGE" ]] || error "No image given (--image PATH, or --help)"
[[ -f "$IMAGE" ]] || error "No such image: ${IMAGE}"
[[ "$(uname -s)" == "Linux" ]] || error "Mounting the image needs Linux; this is $(uname -s)"
command -v trivy >/dev/null 2>&1 || error "trivy is not installed"
command -v losetup >/dev/null 2>&1 || error "losetup is not installed"
[[ "$(id -u)" -eq 0 ]] || error "Needs root for losetup and mount; re-run with sudo"

SARIF_OUT="${SARIF_OUT:-${IMAGE}.sarif}"
JSON_OUT="${JSON_OUT:-${IMAGE}.scan.json}"
SBOM_OUT="${SBOM_OUT:-${IMAGE}.cdx.json}"

#######################################
# Mount the image read-only
#######################################

LOOP=""
MNT="$(mktemp -d)"

# Ordering matters: unmount before detaching, or the detach reports busy and
# the loop device leaks for the life of the runner.
cleanup() {
  # errexit is off for the whole function: a failed umount must not skip the
  # detach below it, nor turn a successful scan into a failed one.
  set +e
  mountpoint -q "$MNT" && umount "$MNT"
  [[ -n "$LOOP" ]] && losetup -d "$LOOP"
  rmdir "$MNT"
  return 0
}
trap cleanup EXIT

LOOP=$(losetup -f --show -P -r "$IMAGE") || error "Could not attach ${IMAGE} to a loop device"
info "Attached as ${LOOP}"

# udev has not necessarily probed the partitions this created, and lsblk reads
# its cache: without this the FSTYPE column comes back empty for every one.
command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=30 || true

# Pick the root filesystem: the largest partition carrying a mountable
# filesystem. mkosi images vary between ext4, erofs and squashfs, and carry an
# ESP that must not be mistaken for the root.
# blkid -p probes the device itself rather than trusting the udev cache, so a
# partition that appeared a moment ago is still identified.
ROOT_PART=""
while read -r name size; do
  dev="/dev/${name}"
  [[ "$dev" == "$LOOP" ]] && continue
  fstype=$(blkid -p -s TYPE -o value "$dev" 2>/dev/null || true)
  case "$fstype" in
    ext2|ext3|ext4|xfs|btrfs|erofs|squashfs) ROOT_PART="$dev"; info "Root candidate ${dev} (${fstype}, ${size})"; break ;;
  esac
done < <(lsblk -nro NAME,SIZE "$LOOP" | sort -k2 -h -r)

if [[ -z "$ROOT_PART" ]]; then
  # No partition table, or a bare filesystem image.
  ROOT_PART="$LOOP"
  warn "No partitioned filesystem found; trying ${LOOP} directly"
fi

mount -o ro "$ROOT_PART" "$MNT" || error "Could not mount ${ROOT_PART}"
log "Mounted ${ROOT_PART} read-only"

if [[ -r "${MNT}/etc/os-release" ]]; then
  info "Guest OS: $(sed -n 's/^PRETTY_NAME=//p' "${MNT}/etc/os-release" | tr -d '\"')"
else
  warn "No /etc/os-release in the image; trivy may not identify the distribution"
fi

#######################################
# Scan
#######################################

# One scan, two renderings. --exit-code stays 0 so the gate below can report
# before the script exits; trivy's own exit code would skip the summary.
#
# Deliberately NOT --ignore-unfixed: that drops those findings from the report
# entirely, so the SARIF would hide them from code scanning rather than merely
# excluding them from the gate. The fixed/unfixed choice belongs in the gate.
trivy rootfs \
  --scanners vuln,secret,license \
  --format json \
  --output "$JSON_OUT" \
  --exit-code 0 \
  --no-progress \
  "$MNT" || error "trivy failed to scan the mounted image"

trivy convert --format sarif --output "$SARIF_OUT" "$JSON_OUT"
trivy convert --format table --severity "$SEVERITY" "$JSON_OUT" || true

# A separate pass: trivy cannot emit CycloneDX and a findings report from one
# run. The SBOM is what makes the image's contents auditable after release.
trivy rootfs --format cyclonedx --output "$SBOM_OUT" --no-progress "$MNT" \
  || error "trivy failed to produce an SBOM"

#######################################
# Gate
#######################################

# Accepted findings are excluded from the gate only -- never from the scan, so
# they stay in the SARIF -- and only until the expiry date each one carries.
ACCEPTED_FILE="${ACCEPTED_FILE:-${SCRIPT_DIR}/../accepted-findings.txt}"

read -r gated unfixed total secrets accepted expired < <(
  python3 -I - "$JSON_OUT" "$SEVERITY" "${IGNORE_UNFIXED:+yes}" "$ACCEPTED_FILE" <<'PY'
import datetime, json, os, sys
doc = json.load(open(sys.argv[1]))
gate = {s.strip().upper() for s in sys.argv[2].split(',') if s.strip()}
skip_unfixed = sys.argv[3] == 'yes'

today, accept = datetime.date.today(), {}
path = sys.argv[4]
if os.path.exists(path):
    for line in open(path):
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        try:
            accept[parts[0]] = datetime.date.fromisoformat(parts[1])
        except (IndexError, ValueError):
            # A malformed entry must not silently widen the gate.
            print(f"malformed entry in {path}: {line!r} (want <CVE-ID> <YYYY-MM-DD>)", file=sys.stderr)
            print(0, 0, 0, 0, 0, 1)
            sys.exit(0)

total = gated = unfixed = secrets = accepted = expired = 0
for res in doc.get('Results') or []:
    for v in res.get('Vulnerabilities') or []:
        total += 1
        if (v.get('Severity') or '').upper() not in gate:
            continue
        if not v.get('FixedVersion'):
            unfixed += 1
            if skip_unfixed:
                continue
        vid = v.get('VulnerabilityID')
        if vid in accept:
            if accept[vid] >= today:
                accepted += 1
                continue
            expired += 1
        gated += 1
    secrets += len(res.get('Secrets') or [])
print(gated, unfixed, total, secrets, accepted, expired)
PY
)

echo ""
info "SARIF:   ${SARIF_OUT}"
components=$(python3 -I -c '
import json, sys
print(len(json.load(open(sys.argv[1])).get("components") or []))
' "$SBOM_OUT") || error "Could not read the SBOM at ${SBOM_OUT}"
info "SBOM:    ${SBOM_OUT} (${components} components)"
info "Findings: ${total} vulnerabilities total, ${gated} gating at ${SEVERITY}, ${secrets} secrets"
if ((unfixed > 0)); then
  # Reported either way: they are in the SARIF regardless of the gate.
  info "${unfixed} finding(s) at ${SEVERITY} have no fix available${IGNORE_UNFIXED:+ (not gating)}"
fi
if [[ -n "$IGNORE_UNFIXED" ]]; then
  warn "--ignore-unfixed is set: findings with no fix do not gate this run"
fi

# A pod VM carries kata-agent and the forwarder at minimum, so an empty SBOM
# means nothing was identified rather than nothing being wrong.
if [[ "$components" == "0" ]]; then
  error "The SBOM is empty: trivy identified nothing in ${ROOT_PART}, so this image is unscanned, not clean."
fi

if ((secrets > 0)); then
  error "${secrets} secret(s) found in the image — a pod VM image must carry none"
fi

if ((expired > 0)); then
  error "${expired} accepted finding(s) are past their expiry date in ${ACCEPTED_FILE##*/}. Re-justify with a new date, or fix them."
fi

if ((accepted > 0)); then
  info "${accepted} finding(s) accepted by ${ACCEPTED_FILE##*/} and not gating; they remain in the SARIF"
fi

if ((gated > 0)); then
  error "${gated} finding(s) at ${SEVERITY}. Clear them at source, accept one in ${ACCEPTED_FILE##*/} with a date, or re-run with a narrower --severity."
fi

log "Clean at ${SEVERITY}${IGNORE_UNFIXED:+ (unfixed findings not counted)}"
exit 0
