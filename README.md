# aws-sandbox-kata-podvm

Nightly builds of the **pod VM image** that backs Conduct's Kata peer-pod
sandboxes on AWS: scanned, attested, and built from pinned
[Confidential Containers](https://confidentialcontainers.org/) source.

> ⛔️ Work in progress and experimental.

## What a pod VM is

Normally a Kubernetes pod runs as containers on the worker node, isolated by
namespaces and cgroups. With Kata **peer pods**, each sandbox instead gets its
own virtual machine — on AWS, one EC2 instance per sandbox. That VM is the
*pod VM*, and the disk image it boots is what this repository builds.

It is not a general-purpose Linux box. It is a minimal appliance carrying:

- `kata-agent`, which runs the actual containers inside the VM
- `agent-protocol-forwarder`, the control channel `cloud-api-adaptor` talks to
- enough systemd and userspace to boot and attest

`cloud-api-adaptor` sees a pod with `runtimeClassName: kata-remote`, calls EC2
`RunInstances` with this image, and the pod runs inside that VM. Pod traffic
tunnels back to the worker node over VXLAN, so Kubernetes NetworkPolicy still
applies. The point is a **VM boundary** around untrusted workloads rather than
a container boundary.

## These are not confidential VMs

Worth stating plainly, because the upstream project is called *Confidential
Containers* and the name invites the opposite assumption.

This image is built with `TEE_PLATFORM=none`, and the deployment sets
`DISABLECVM: "true"`. What that buys is a **VM isolation boundary**: an
untrusted sandbox workload runs in its own EC2 instance and cannot reach the
worker node's kernel. What it does **not** buy is confidential computing —
there is no SEV-SNP attestation, and the hypervisor and host operator remain in
the trust boundary.

Upstream's AWS guide says to set `TEE_PLATFORM=amd`, which builds the SEV-SNP
attester and requires SEV-SNP-capable instance types. That is a separate and
larger decision about hardware and an attestation service. If confidential
computing becomes a requirement, this is the setting that changes — and the
instance types, and the key-release design, change with it.

## Why this repository exists

Because nothing trustworthy is published for AWS, and we need the boundary to
be trustworthy. This is not a preference; it is the documented path.

- **The upstream project says to build it yourself.** From the
  [AWS guide](https://confidentialcontainers.org/docs/examples/aws-simple/):
  "There are no pre-built pod VM AMI for latest builds" and "You'll need to
  build your own pod VM image and then create the AMI". The only prebuilt
  option is "a pre-built **debug** pod VM image available in `us-east-2` for
  PoCs" — one region, debug variant, explicitly for proofs of concept.
- **What upstream distributes for AWS is a qcow2, not an AMI.** From
  [consuming-prebuilt-podvm-images.md](https://github.com/confidential-containers/cloud-api-adaptor/blob/main/src/cloud-api-adaptor/docs/consuming-prebuilt-podvm-images.md):
  "You can use the qcow2 to create provider specific image (eg. AWS AMI …)".
  Turning it into an AMI in your own account *is* building a custom image.
- **The commercial product does the same thing.** Red Hat ships no prebuilt
  AMI; the [OpenShift sandboxed containers operator](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_openshift_sandboxed_containers_on_aws/configure-osc-overview_aws-osc)
  "creates a pod VM image" in the customer's own account via an
  `osc-podvm-image-creation` job. We are making the same decision, in CI rather
  than an in-cluster job.
- **Upstream publishes no AWS image.** Their workflows include
  `podvm_azure_image_publish.yaml`; there is no AWS equivalent.
- **The published OCI artifact is unattested.** Upstream's publish workflow
  requests `attestations: write`, but no provenance record resolves for the
  released digest:
  ```console
  $ gh attestation verify oci://quay.io/confidential-containers/podvm-generic-ubuntu-amd64:v0.22.0 \
      --owner confidential-containers
  Error: HTTP 404: Not Found
  ```
- **Upstream does not publish one for every release.** `podvm-generic-ubuntu-amd64`
  carries a `v0.22.0` tag but **no `v0.23.0`** — the version this repository now
  pins. For it there is no upstream artifact to import at all, debug or
  otherwise.
- **The only public AMI we found is a debug build**, from an AWS account we
  could not tie to the project, in a single region, with a snapshot that is
  not public. The debug variant enables serial console access into the pod VM,
  which is precisely at odds with the VM's purpose.

So the image is built here, from pinned upstream source, scanned, and attested
with `actions/attest-build-provenance`. Because this repository is public,
those attestations are independently verifiable by anyone — which is the whole
reason for owning the build.

## What the nightly run does

`cloud-api-adaptor` is pinned, so the source does not move between runs. What
moves is the Ubuntu package set `mkosi` pulls, so a rebuild does take whatever
distribution fixes have landed since the last one.

Be precise about what that is worth, because two things limit it:

- **You cannot evidence it.** The image ships no dpkg database (`/var/lib/dpkg`
  and `/var/lib/apt` are both absent), so no scanner can enumerate the Ubuntu
  packages. An `os-pkgs` result of zero means nothing was identified, not that
  nothing is wrong. The scan below gates on what it *can* see — the Go binaries.
- **It does not touch the Go toolchain or module dependencies.** Those are
  pinned by the CAA ref's `versions.yaml` and `go.mod`, so rebuilding the same
  ref reproduces the same stdlib and module CVEs however often you run it.
  Clearing those needs the pin moved, or `--go-version` to lift the toolchain
  on its own.

So the nightly's real product is a **freshly attested artifact** and early
warning that the build still works — not a continuously patched image. Each run:

1. Builds the image from the pinned CAA ref with `mkosi`. The build script can
   verify upstream's attestations on the `kata-agent` and guest-component
   binaries as it pulls them (`VERIFY_PROVENANCE=yes`, its default), but the
   nightly turns that off with `--no-verify-provenance` for now: upstream's
   check cannot discover the attestation through ghcr, so those binaries are
   taken on trust until it can.
2. Mounts the result read-only and scans the root filesystem with trivy for
   vulnerabilities and secrets.
3. Publishes the image to `ghcr.io/unique-ag/aws-sandbox-kata-podvm` as an OCI
   artifact — **only if the scan passed** — tagged `nightly-YYYYMMDD` and
   `nightly`. A manual run from another branch, of another CAA ref or with the
   scratch patch gets its own tag and cannot move `nightly`.
4. Attests build provenance and the SBOM against the **published digest**, with
   `push-to-registry`, so both resolve from the registry.
5. Keeps the SARIF, SBOM and `.provenance` record as a run artifact for triage.

A failing scan publishes nothing and attests nothing. The findings still reach
the Security tab, and the SARIF, SBOM and `.provenance` record are kept as a
run artifact. The rejected image itself is not kept: this repository is public,
so anyone signed in to GitHub could download a run artifact, and an image that
failed its scan should not be handed out. To triage one, build the same commit
locally (see [Building locally](#building-locally)).

### Where the image lands

`ghcr.io/unique-ag/aws-sandbox-kata-podvm`, as a zstd-compressed OCI artifact — the
same distribution model upstream uses for its own pod VM images.

```bash
# Resolve the tag once, so you verify the same image you pull:
digest=$(oras resolve ghcr.io/unique-ag/aws-sandbox-kata-podvm:nightly)

# Build provenance (SLSA) and the SBOM (CycloneDX), both from the registry:
gh attestation verify "oci://ghcr.io/unique-ag/aws-sandbox-kata-podvm@${digest}" --owner unique-ag
gh attestation verify "oci://ghcr.io/unique-ag/aws-sandbox-kata-podvm@${digest}" --owner unique-ag \
  --predicate-type https://cyclonedx.org/bom

oras pull "ghcr.io/unique-ag/aws-sandbox-kata-podvm@${digest}"
tar -I zstd -xf podvm.tar.zst
```

A run artifact would not do: it expires after 14 days and is addressable only
by run id, so promoting a three-week-old build would be impossible and nothing
could pull it without the Actions API. The registry gives each build an
immutable digest that promotion can name.

Attestation is against the **published digest** rather than the local file,
which is what makes `gh attestation verify oci://…` work. That is precisely
the step that does not resolve for the upstream artifact.

> On first publish GitHub creates the package private. An organisation owner
> makes it public once, in the package settings; until then `oras pull` asks
> anonymous users for credentials.

This registry copy is the public build output, there to be verified. It is
not what a cluster boots: an installation runs a private AMI, encrypted with
its account's key, made from an attested digest (see
[Promotion to an AMI](#promotion-to-an-ami)).

### No AMI is registered

Deliberately. The image is an artifact; turning one into an AMI is a separate,
deliberate act — see **Promotion** below. A nightly that registered an AMI
would leave ~365 AMIs and snapshots a year behind it, while consumers pin
exactly one id.

## What scans what

GitHub Advanced Security covers the repository; the workflows cover the image
and the pipeline. The overlap is deliberate where the tools see different
things, and noted where it is genuine.

| Layer | Tool | Why not just GHAS |
| --- | --- | --- |
| Repository secrets | GHAS secret scanning + push protection | — (on by default) |
| Repository secrets | gitleaks (`secret.scan.yaml`) | GHAS matches known provider patterns; gitleaks adds entropy and regex rules over the PR's commit range |
| Dependencies | Dependabot security updates | — (on by default) |
| Workflows | CodeQL `actions` | — (default setup) |
| Workflows | zizmor (`lint.yaml`) | Overlaps CodeQL on template injection, adds unpinned actions, cache and artifact poisoning, over-broad permissions |
| Shell scripts | shellcheck | Not covered by CodeQL |
| **The image** | trivy: vuln, secret, license | Nothing in GHAS scans a VM disk image |
| **The image** | CycloneDX SBOM, attested | Lets a consumer audit contents without mounting it |

Third-party findings upload as SARIF, so trivy and zizmor alerts appear in the
Security tab beside the GHAS ones rather than only in build logs.

## Building locally

Requires **Linux with Docker** — `mkosi` builds inside a privileged container
and cannot run on macOS. The build script checks the host first:

```bash
./scripts/build-podvm-image.sh --check    # confirm the host
./scripts/build-podvm-image.sh --out build
sudo ./scripts/scan-image.sh --image build/podvm-*.raw
```

The build writes a `.provenance` file next to the image recording the CAA ref
and commit, the mkosi version, the make target and the SHA256, so a later
import can prove it received that exact artifact.

The scan needs root: trivy cannot read a raw disk directly (`trivy vm` handles
VMDK and live AMIs, not a local `.raw`), so the script attaches the image to a
loop device, mounts the root filesystem read-only and runs `trivy rootfs`
against the mount. It fails on **any** HIGH or CRITICAL finding, whether or not
a fix exists yet, and on **any** secret — a pod VM image should carry none.

Having no fix available is not a reason to ship it: an unfixed CRITICAL is still
a CRITICAL in the image that boots. `--ignore-unfixed` exists to exclude them
deliberately, and the run says so in its output when it is used, but the default
is strict. Either way the findings are in the SARIF, because the scan itself is
never narrowed — only the gate is.

A finding can be accepted in `accepted-findings.txt`, one `<CVE-ID> <YYYY-MM-DD>`
per line with the reasoning above it. An acceptance is deliberately weak: the
scan still reports the finding, so it stays in the SARIF and in code scanning,
and the exemption applies **only to the pass/fail gate and only until its date**.
Past that the finding gates again and the run says so, so an acceptance cannot be
quietly forgotten. A malformed entry fails the scan rather than widening the gate.

Nothing is accepted at present. The build raises `golang.org/x/net` with
`--go-mod-bump` instead, now to 0.62.0, which clears `CVE-2026-78661`. An earlier
bump to 0.60.0 cleared `CVE-2026-78669`, which had been accepted until then; fixing
a finding is preferable to accepting it, and the reason the acceptance was removed
rather than left to expire.

## The scratch-disk experiment

`--scratch-no-integrity` (and the matching `scratch_no_integrity` workflow input) builds an
image whose scratch disk is LUKS-encrypted **without dm-integrity**. It exists to test one
specific failure.

Upstream's `setup-scratch-storage` calls `luks-encrypt-storage` with four arguments, but that
script reads `data_integrity` from the **fifth**. It therefore defaults to `true`, and the
scratch disk is formatted `--integrity hmac-sha256 --integrity-no-wipe`. An un-wiped integrity
device has invalid checksums on every sector nothing has written yet, so a read of one fails:

```
trusted_key: device-mapper: crypt: dm-1: INTEGRITY AEAD ERROR, sector 0
```

Upstream's own comment in `luks-encrypt-storage` describes this hazard and pre-writes the
blocks `mkfs.ext4` will touch — a workaround it says can still lose to kernel buffering.
Without usable scratch storage the guest has only a small overlay, which is too little to
unpack a large sandbox image.

The flag appends the missing fifth argument, taking the plain-LUKS branch instead. **It trades
per-block integrity authentication for a working disk**, keeping confidentiality. That is a
real reduction and is only defensible where the host is trusted — which is the case for
non-confidential peer pods (`DISABLECVM=true`), not under the CoCo threat model.

Two guards, because this image is otherwise an unmodified upstream build:

- the build **fails** rather than silently skipping if upstream's call no longer matches;
- `scratch_no_integrity=yes` is written to the provenance file, and the publish step reads it
  back so such a build is tagged `experiment-scratch-no-integrity-<sha>` and **can never claim
  the `nightly` tag** that promotion pulls.

Upstream deprecated encrypted scratch space in v0.23.0 and proposes removing it in 0.24, so
treat this as an experiment that buys time, not a destination.

## Promotion to an AMI

> Not yet implemented. Tracked as the follow-up to the initial build pipeline.

Promotion takes an attested artifact from a successful nightly run, verifies
its attestation and its `.provenance` record, imports it via VM Import/Export,
registers an AMI with the boot properties the remote hypervisor requires
(UEFI, `TpmSupport=v2.0`, IMDSv2-only, encrypted), and prints the id to pin.

It needs two things that do not exist yet:

- a GitHub OIDC role in the publishing account trusting **this** repository —
  the existing role trusts `Unique-AG/hello-aws` only
- the VM Import staging bucket and `vmimport` role, which today live behind
  `enable_podvm_image_import` in `hello-aws`'s compute layer and belong here

## Relationship to hello-aws

[`hello-aws`](https://github.com/Unique-AG/hello-aws) consumes the result. It
holds the `peerpods` chart whose `appVersion` **must match** the CAA ref built
here, and `instance-config.yaml` pins the AMI id that `cloud-api-adaptor`
launches. Keep the two in step: an image built from a different CAA ref than
the chart expects will boot and then fail to attest, which is a slow thing to
diagnose.
