#!/usr/bin/env bash
#######################################
# Conduct Pod VM Image Build Script
#######################################
#
# Builds the Confidential Containers pod VM disk image from source with mkosi,
# pinned to the CAA version the peerpods chart vendors. Writes
# podvm-<ref>-<arch>[-debug].raw, prints its SHA256 for hello-aws's
# import-podvm-ami.sh to verify, and records the build inputs in a .provenance
# file next to the image.
#
# Runs upstream's build. Two opt-in options change the source first, and the
# .provenance file records both: --go-mod-bump and --scratch-no-integrity.
# Requires Linux with Docker; the mkosi build needs a privileged container and
# cannot run on macOS.
#
# Usage:
#   ./build-podvm-image.sh [options]
#
# Options:
#   -r, --ref REF         CAA git ref to build (default: the pinned version)
#   -o, --out DIR         Where to place the image (default: $TMPDIR/podvm-build)
#       --debug-image     Build upstream's debug variant instead
#       --go-version VER  Build with this Go toolchain instead of the pinned one
#       --go-mod-bump M@V Raise one Go module before building (repeatable)
#       --go-image IMG    Go image for --go-mod-bump, required with it, as
#                         golang:<build's Go version>@sha256:<digest>
#       --scratch-no-integrity
#                         Format the pod VM scratch disk without dm-integrity
#       --no-verify-provenance
#                         Skip attestation checks on upstream's binaries
#       --check           Check host prerequisites and exit
#   -h, --help            Show this help message
#
# Examples:
#   # Confirm the host can build before committing to it
#   ./build-podvm-image.sh --check
#
#   # Build the pinned version
#   ./build-podvm-image.sh
#######################################

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

#######################################
# Defaults
#######################################

# Must match the appVersion of 06-applications/charts/peerpods.
PINNED_REF="v0.23.0"
CAA_REPO="https://github.com/confidential-containers/cloud-api-adaptor"

APT_DEPS=(git make qemu-utils uidmap)  # plus yq 4.x

CAA_REF="$PINNED_REF"
OUT_DIR="${TMPDIR:-/tmp}/podvm-build"
MAKE_TARGET="all"
CHECK_ONLY=false
# Upstream defaults this off. On, the build verifies GitHub attestations for the
# kata-agent and guest-component binaries it pulls before baking them in.
VERIFY_PROVENANCE="yes"
# Empty means upstream's versions.yaml pin. Set it to remediate stdlib CVEs
# without waiting for upstream to move; it is recorded in the provenance file.
GO_VERSION=""
# Modules raised in the CAA source before building, as module@version. For
# clearing a CVE upstream has already fixed on main but not yet released.
GO_MOD_BUMPS=()
# The image the bumps run in, pinned by digest; no default, so a tag never decides.
GO_IMAGE=""
# setup-scratch-storage passes four arguments, but luks-encrypt-storage reads
# data_integrity from the fifth, so it defaults to true and the scratch disk is
# formatted --integrity-no-wipe. Reads of unwritten sectors then fail with
# INTEGRITY AEAD ERROR and the guest cannot unpack an image. Setting this drops
# dm-integrity and keeps LUKS; recorded in the provenance file.
SCRATCH_NO_INTEGRITY="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--ref)       need_value "$@"; CAA_REF="$2"; shift 2 ;;
    -o|--out)       need_value "$@"; OUT_DIR="$2"; shift 2 ;;
    --debug-image)  MAKE_TARGET="debug"; shift ;;
    --no-verify-provenance) VERIFY_PROVENANCE="no"; shift ;;
    --go-version)   need_value "$@"; GO_VERSION="$2"; shift 2 ;;
    --go-mod-bump)  need_value "$@"; GO_MOD_BUMPS+=("$2"); shift 2 ;;
    --go-image)     need_value "$@"; GO_IMAGE="$2"; shift 2 ;;
    --scratch-no-integrity) SCRATCH_NO_INTEGRITY="yes"; shift ;;
    --check)        CHECK_ONLY=true; shift ;;
    -h|--help)      print_help "${BASH_SOURCE[0]}"; exit 0 ;;
    *)              error "Unknown option: $1 (try --help)" ;;
  esac
done

#######################################
# Host prerequisites
#######################################

MISSING=()

[[ "$(uname -s)" == "Linux" ]] \
  || error "The mkosi build needs Linux with Docker; this is $(uname -s). Run it on a Linux host or a CI runner."

# Only what the host itself runs: yq reads the pinned mkosi version below.
# oras, gh and jq are installed inside Dockerfile.podvm_binaries, and
# bwrap/dnf belong to the s390x path.
command -v docker >/dev/null 2>&1 || MISSING+=("docker")
docker buildx version >/dev/null 2>&1 || MISSING+=("docker-buildx")
command -v git >/dev/null 2>&1 || MISSING+=("git")
command -v qemu-img >/dev/null 2>&1 || MISSING+=("qemu-utils")
command -v make >/dev/null 2>&1 || MISSING+=("make")
# Behavioural, not a version string: python-yq also calls itself yq and emits
# JSON-quoted scalars, which would pin MKOSI_VERSION to a quoted value.
if command -v yq >/dev/null 2>&1; then
  [[ "$(printf 'a: b\n' | yq -e '.a' 2>/dev/null)" == "b" ]] \
    || MISSING+=("yq (mikefarah 4.x; found $(yq --version 2>&1))")
else
  MISSING+=("yq (mikefarah 4.x)")
fi

if ((${#MISSING[@]})); then
  warn "Missing prerequisites: ${MISSING[*]}"
  echo ""
  echo "On Debian/Ubuntu:"
  echo "    sudo apt-get install -y ${APT_DEPS[*]}"
  echo "    # plus Docker with buildx"
  $CHECK_ONLY && exit 1
  error "Cannot build until these are present"
fi

docker info >/dev/null 2>&1 || { $CHECK_ONLY && { warn "Docker is installed but not usable by this user"; exit 1; }; error "Docker is not usable by this user"; }

log "Host looks able to build"
if $CHECK_ONLY; then
  info "Would build ${CAA_REF} into ${OUT_DIR}"
  exit 0
fi

#######################################
# Fetch the pinned source
#######################################

[[ "$CAA_REF" == "$PINNED_REF" ]] \
  || warn "Building ${CAA_REF}, not the pinned ${PINNED_REF} — the image must match the chart's appVersion"

mkdir -p "$OUT_DIR"
# Docker reads a relative -v source as a named volume, not a bind mount.
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
SRC_DIR="${OUT_DIR}/cloud-api-adaptor"

if [[ -d "$SRC_DIR/.git" ]]; then
  info "Reusing ${SRC_DIR}"
  git -C "$SRC_DIR" fetch --depth 1 origin "$CAA_REF" --quiet
  # reset+clean, not checkout: an earlier --go-mod-bump edits tracked files, and
  # checkout keeps them when the ref is unchanged, so the next build inherits them.
  git -C "$SRC_DIR" reset --hard --quiet FETCH_HEAD
  git -C "$SRC_DIR" clean -qfdx
else
  info "Cloning ${CAA_REF}"
  git clone --depth 1 --branch "$CAA_REF" --quiet "$CAA_REPO" "$SRC_DIR"
fi

SRC_SHA=$(git -C "$SRC_DIR" rev-parse HEAD)
log "Source at ${SRC_SHA}"

PODVM_DIR="${SRC_DIR}/src/cloud-api-adaptor/podvm"
[[ -d "$PODVM_DIR" ]] || error "No podvm directory at ${CAA_REF}; the upstream layout has moved"

#######################################
# Build
#######################################

# Run in a container of the build's own Go toolchain, so the host needs no Go;
# the bumps are recorded in the provenance file.
if ((${#GO_MOD_BUMPS[@]})); then
  # Mount all of src/, not just cloud-api-adaptor: its go.mod replaces sibling
  # modules with ../ paths, which do not resolve from a narrower mount.
  CAA_SRC="${SRC_DIR}/src"
  GO_WANT="${GO_VERSION:-$(yq -e '.tools.golang' "${CAA_SRC}/cloud-api-adaptor/versions.yaml")}"
  GO_IMAGE_RE='^[^@]+:([^@:/]+)@sha256:[0-9a-f]{64}$'
  [[ "$GO_IMAGE" =~ $GO_IMAGE_RE ]] \
    || error "--go-mod-bump needs --go-image golang:${GO_WANT}@sha256:<digest>, got '${GO_IMAGE}'"
  [[ "${BASH_REMATCH[1]}" == "$GO_WANT" ]] \
    || error "--go-image is Go ${BASH_REMATCH[1]}, but this build uses Go ${GO_WANT}"
  docker pull --quiet "$GO_IMAGE" >/dev/null || error "Could not pull ${GO_IMAGE}"
  info "Go toolchain ${GO_IMAGE}"
  for bump in "${GO_MOD_BUMPS[@]}"; do
    [[ "$bump" == *@* ]] || error "--go-mod-bump expects module@version, got '${bump}'"
    info "Raising ${bump}"
    docker run --rm -v "${CAA_SRC}:/src" -w /src/cloud-api-adaptor "$GO_IMAGE" \
      go get "$bump" || error "Could not raise ${bump}"
  done
  # go get runs as root in the container; hand the tree back to the caller.
  docker run --rm -v "${CAA_SRC}:/src" -w /src "$GO_IMAGE" \
    chown -R "$(id -u):$(id -g)" /src
fi

if [[ "$SCRATCH_NO_INTEGRITY" == "yes" ]]; then
  SCRATCH_SETUP="${SRC_DIR}/src/cloud-api-adaptor/podvm/files/usr/local/bin/setup-scratch-storage"
  [[ -f "$SCRATCH_SETUP" ]] || error "Not found: ${SCRATCH_SETUP}"
  # Fail loudly if upstream changed the call, rather than silently not patching.
  grep -qE 'luks-encrypt-storage "\$DEV_NUM" false "\$MOUNT_POINT" [^ ]+$' "$SCRATCH_SETUP" \
    || error "setup-scratch-storage no longer matches the expected call; re-check --scratch-no-integrity"
  sed -i.bak -E 's#(luks-encrypt-storage "\$DEV_NUM" false "\$MOUNT_POINT" [^ ]+)$#\1 false#' "$SCRATCH_SETUP"
  rm -f "${SCRATCH_SETUP}.bak"
  info "Scratch disk: LUKS without dm-integrity"
fi

# TEE_PLATFORM is left at its default of "none": the overlay sets
# DISABLECVM=true, so no attester beyond the filesystem one is needed.
MKOSI_VERSION=$(yq -e '.tools.mkosi' "${SRC_DIR}/src/cloud-api-adaptor/versions.yaml")
info "mkosi ${MKOSI_VERSION}, target '${MAKE_TARGET}', TEE_PLATFORM=none"
if [[ "$VERIFY_PROVENANCE" == "yes" ]]; then
  info "Verifying upstream binary attestations as they are pulled"
else
  warn "Provenance verification disabled — upstream binaries are taken on trust"
fi
warn "This takes a while and needs a privileged container"

# On the command line, not the environment: make lets an exported variable win
# over the Makefile's ?=, which would build something the record does not match.
make -C "$PODVM_DIR" "$MAKE_TARGET" \
  MKOSI_VERSION="$MKOSI_VERSION" \
  VERIFY_PROVENANCE="$VERIFY_PROVENANCE" \
  ${GO_VERSION:+GO_VERSION="$GO_VERSION"} \
  TEE_PLATFORM=none

RAW="${PODVM_DIR}/build/system.raw"
[[ -f "$RAW" ]] || error "Build finished but ${RAW} is missing"

# The image target also converts to qcow2, which nothing here needs.
rm -f "${PODVM_DIR}"/build/podvm-*.qcow2

#######################################
# Report
#######################################

VARIANT_SUFFIX=""
[[ "$MAKE_TARGET" == "debug" ]] && VARIANT_SUFFIX="-debug"
FINAL="${OUT_DIR}/podvm-${CAA_REF}-$(uname -m)${VARIANT_SUFFIX}.raw"
mv "$RAW" "$FINAL"
SHA=$(sha256sum "$FINAL" | cut -d' ' -f1)

# Recorded next to the image so the import can prove it got this artifact.
cat > "${FINAL}.provenance" <<PROV
caa_ref=${CAA_REF}
caa_commit=${SRC_SHA}
mkosi_version=${MKOSI_VERSION}
make_target=${MAKE_TARGET}
verify_provenance=${VERIFY_PROVENANCE}
tee_platform=none
go_version=${GO_VERSION:-$(yq -e '.tools.golang' "${SRC_DIR}/src/cloud-api-adaptor/versions.yaml")}
go_mod_bumps=${GO_MOD_BUMPS[*]:-none}
scratch_no_integrity=${SCRATCH_NO_INTEGRITY}
go_image=${GO_IMAGE:-none}
sha256=${SHA}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PROV

echo ""
log "Built ${BOLD}${FINAL}${NC}"
echo "    size:   $(du -h "$FINAL" | cut -f1)"
echo "    sha256: ${SHA}"
echo "    source: ${CAA_REF} @ ${SRC_SHA}"
echo ""
echo "Scan it with:"
echo ""
echo "    ./scripts/scan-image.sh --image ${FINAL}"
echo ""
[[ "$MAKE_TARGET" == "debug" ]] && warn "Debug variant: serial console access is enabled. Do not use it as a sandbox boundary."
exit 0
