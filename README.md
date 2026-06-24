# proverjay

`proverjay` is a deliberately small demo of Kubernetes admission control for a release container image with:

- a keyless Cosign signature from this repository's GitHub Actions release workflow
- a keyless SLSA provenance attestation from the SLSA GitHub generator
- a Kyverno `ImageValidatingPolicy` that requires both

This demo assumes the `ghcr.io/h3ow3d/proverjay` package is readable by both the cluster and Kyverno.

## What this demo proves

On semver tags (`v*.*.*`), the repository:

1. tests the Go app
2. builds and pushes `ghcr.io/h3ow3d/proverjay:${GITHUB_SHA}`
3. signs the pushed image by digest with Cosign keyless signing
4. generates SLSA provenance for that same digest
5. lets Kyverno admit `ghcr.io/h3ow3d/proverjay*` images only when both the image signature and SLSA provenance attestation verify

## What this demo does not prove yet

This repo intentionally does **not** yet enforce:

- provenance payload checks such as builder ID or source repository assertions
- SBOM requirements
- vulnerability attestations
- Trivy scanning
- SARIF upload
- non-`proverjay` image verification

## Release workflow

The workflow in `.github/workflows/ci.yaml` runs on:

- pushes to `main`
- pull requests
- semver tags matching `v*.*.*`

It always runs `make test`. It only publishes, signs, and generates provenance on semver tags.

## Manual verification with Cosign

Use an immutable image reference:

```bash
IMAGE=ghcr.io/h3ow3d/proverjay
DIGEST=sha256:<release-digest>
IMAGE_REF="${IMAGE}@${DIGEST}"
```

Verify the release signature:

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/h3ow3d/proverjay/\.github/workflows/ci\.ya?ml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
  "${IMAGE_REF}"
```

Verify the SLSA provenance attestation signature:

```bash
cosign verify-attestation \
  --type slsaprovenance \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/slsa-framework/slsa-github-generator/\.github/workflows/generator_container_slsa3\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
  "${IMAGE_REF}"
```

Local helper targets use the same checks:

```bash
make verify-image
make verify-provenance
```

## Kyverno admission policy

The policy lives at `deploy/kyverno/require-signed-proverjay-image.yaml`.

It uses the modern `ImageValidatingPolicy` API and does only two checks for `ghcr.io/h3ow3d/proverjay*` images:

1. `verifyImageSignatures(...)`
2. `verifyAttestationSignatures(...)` for `https://slsa.dev/provenance/v0.2`

## Test Kyverno admission

Apply Kyverno, then apply the policy:

```bash
make install-kyverno
make kyverno-apply-policies
```

Use a known-good release from the current flow and an older release that predates provenance. Replace these example tags with the latest good release and an older pre-provenance release if newer tags exist:

```bash
GOOD_IMAGE=ghcr.io/h3ow3d/proverjay:v0.1.10
BAD_IMAGE=ghcr.io/h3ow3d/proverjay:v0.1.4
```

The good image should be admitted:

```bash
kubectl apply --dry-run=server -f - <<EOF2
apiVersion: v1
kind: Pod
metadata:
  name: proverjay-good
spec:
  containers:
    - name: app
      image: ${GOOD_IMAGE}
      command: ["sleep", "3600"]
EOF2
```

The older image should be denied because it predates the current provenance flow:

```bash
kubectl apply --dry-run=server -f - <<EOF2
apiVersion: v1
kind: Pod
metadata:
  name: proverjay-bad
spec:
  containers:
    - name: app
      image: ${BAD_IMAGE}
      command: ["sleep", "3600"]
EOF2
```

## Offline Harbor + k3d demo

### Architecture (text diagram)

```text
Online build/sign side
  GitHub Actions (tag release)
    -> ghcr.io/h3ow3d/proverjay:<tag>
    -> cosign signature + SLSA provenance referrers
    -> scripts/offline-export.sh (ORAS recursive OCI-layout export)
    -> dist/proverjay-<tag>.oci-bundle.tar.gz

Transfer (USB/scp/sneakernet)
  bundle.tar.gz + bundle.sha256

Offline promotion side
  scripts/offline-import-harbor.sh (ORAS recursive OCI-layout import)
    -> Harbor VM: harbor.proverjay.test/proverjay/proverjay:<tag>

Offline runtime side
  k3d cluster (trusts Harbor CA, resolves harbor.proverjay.test)
    -> Kyverno require-private-harbor-source (deny non-Harbor images)
    -> Kyverno require-signed-proverjay-harbor-image (signature + SLSA required)
    -> deploy/k8s/deployment-harbor.yaml admitted only when policy checks pass
```

### Online export commands

```bash
make offline-export RELEASE_IMAGE=ghcr.io/h3ow3d/proverjay:v0.1.10
ls -lh dist/proverjay-v0.1.10.oci-bundle.tar.gz*
```

### Transfer bundle to offline environment

```bash
# Example transfer mechanism is environment-specific.
# Always transfer both bundle and checksum file.
sha256sum -c dist/proverjay-v0.1.10.oci-bundle.tar.gz.sha256
```

### Offline Harbor import commands

```bash
oras login harbor.proverjay.test

make offline-import-harbor \
  BUNDLE=dist/proverjay-v0.1.10.oci-bundle.tar.gz \
  HARBOR_HOSTNAME=harbor.proverjay.test \
  HARBOR_PROJECT=proverjay \
  HARBOR_IMAGE=proverjay \
  HARBOR_TAG=v0.1.10
```

### k3d cluster creation (Harbor-aware)

```bash
# ensure Harbor CA exists at infra/harbor/harbor-ca.crt
make cluster-create-harbor
make cluster-check
```

Harbor-specific k3d files:

- `infra/k3d/cluster-harbor.yaml`
- `infra/k3d/registries-harbor.yaml`
- `infra/harbor/README.md`

### Kyverno policy install commands

```bash
make install-kyverno
make kyverno-apply-harbor-policies
```

### Deploy commands

```bash
make k8s-deploy-harbor
make harbor-demo-status
```

### Expected pass/fail admission tests

Use `kubectl apply --dry-run=server -f ...` pods with each image case:

- ✅ admitted: `harbor.proverjay.test/proverjay/proverjay:<valid-signed-and-attested-tag>`
- ❌ denied: `ghcr.io/h3ow3d/proverjay:<tag>` (fails private-registry policy)
- ❌ denied: `docker.io/library/nginx:latest` (fails private-registry policy)
- ❌ denied: Harbor image without valid signature/provenance (fails signing/attestation policy)

### Troubleshooting

- Harbor CA trust in k3d:
  - ensure `infra/harbor/harbor-ca.crt` is present and valid for `harbor.proverjay.test`
  - recreate cluster after CA updates
- DNS/hostname mapping from k3d nodes to libvirt VM:
  - update `extraHosts` in `infra/k3d/cluster-harbor.yaml` to correct Harbor VM IP
- ORAS referrers not copied:
  - use ORAS v1.3+ and keep `oras cp --recursive` in both export/import
- Kyverno cannot verify keyless signatures offline:
  - keyless verification may require Fulcio/Rekor trust material; keep this as demo limitation
  - future path: key-pair signing mode for fully air-gapped verification
- image tag vs digest mutation issues:
  - `ImageValidatingPolicy` has `mutateDigest: true` and `verifyDigest: true`; prefer digest-pinned references where possible

## Inspect policies and troubleshoot failures

```bash
kubectl get imagevalidatingpolicy
kubectl describe imagevalidatingpolicy require-signed-proverjay-image
kubectl describe imagevalidatingpolicy require-signed-proverjay-harbor-image
kubectl get clusterpolicy require-private-harbor-source
kubectl logs -n kyverno deploy/kyverno-admission-controller
kubectl get events -A | grep -i kyverno
```
