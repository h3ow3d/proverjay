# proverjay

`proverjay` is a deliberately small demo of Kubernetes admission control for a release container image with:

- a Cosign key-pair signature from this repository's GitHub Actions release workflow
- a key-pair signed SLSA provenance attestation emitted by the release workflow
- a Kyverno `ImageValidatingPolicy` that requires both

This demo assumes the `ghcr.io/h3ow3d/proverjay` package is readable by both the cluster and Kyverno.

## What this demo proves

On semver tags (`v*.*.*`), the repository:

1. tests the Go app
2. builds and pushes `ghcr.io/h3ow3d/proverjay:${GITHUB_SHA}`
3. signs the pushed image by digest with the repository Cosign key pair
4. generates and signs a SLSA provenance attestation for that same digest
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
  --key infra/cosign/cosign.pub \
  "${IMAGE_REF}"
```

Verify the SLSA provenance attestation signature:

```bash
cosign verify-attestation \
  --type slsaprovenance \
  --key infra/cosign/cosign.pub \
  "${IMAGE_REF}"
```

Local helper targets use the same checks:

```bash
make verify-image
make verify-provenance
```

## Cosign key setup

The trusted public key is committed at `infra/cosign/cosign.pub`.

Before tagging a release, add these GitHub Actions secrets:

- `COSIGN_PRIVATE_KEY`: the full contents of the matching `cosign.key`
- `COSIGN_PASSWORD`: optional password used when the key pair was generated

If you need to rotate the key pair:

1. generate a new pair with `cosign generate-key-pair`
2. update `infra/cosign/cosign.pub`
3. update both Kyverno policies to trust the new public key
4. deploy the updated policies before relying on new signed tags

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

Use a known-good release from the current key-pair flow and an older release from before the migration. Replace these example tags with the latest good release and an older pre-migration release if newer tags exist:

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
    -> cosign key-pair signature + SLSA provenance referrers
    -> scripts/offline-export.sh (ORAS recursive OCI-layout export)
    -> dist/proverjay-<tag>.oci-bundle.tar.gz

Transfer (USB/scp/sneakernet)
  bundle.tar.gz + bundle.sha256

Offline promotion side
  scripts/offline-import-harbor.sh (ORAS recursive OCI-layout import)
    -> Harbor (Docker Compose): harbor.proverjay.test/proverjay/proverjay:<tag>

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
# ensure Harbor is running (make harbor-setup) before creating the cluster
make harbor-cluster-create
make cluster-check
```

Harbor-specific k3d files:

- `infra/k3d/cluster-harbor-local.yaml.tmpl`
- `infra/k3d/registries-harbor.yaml`
- `infra/harbor/README.md`
- `infra/cosign/cosign.pub`

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
  - CA is generated automatically by `make harbor-setup` at `infra/harbor/harbor-ca.crt`
  - recreate cluster after CA updates
- DNS/hostname mapping from k3d nodes to Harbor:
  - `make harbor-cluster-create` auto-detects the Docker bridge gateway IP
  - override with `HARBOR_HOST_IP=<ip> make harbor-cluster-create` if auto-detection fails
- ORAS referrers not copied:
  - use ORAS v1.3+ and keep `oras cp --recursive` in both export/import
- Kyverno cannot verify signatures after a key rotation:
  - update `infra/cosign/cosign.pub` and both Kyverno policies together
  - old keyless releases will not satisfy the key-pair policy after migration
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
