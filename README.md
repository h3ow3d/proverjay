# proverjay

`proverjay` is a deliberately small demo of Kubernetes admission control for a release container image with:

- a keyless Cosign signature from this repository's GitHub Actions release workflow
- a keyless SLSA provenance attestation from the SLSA GitHub generator
- a Kyverno `ImageValidatingPolicy` that requires both

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

The workflow in `/home/runner/work/proverjay/proverjay/.github/workflows/ci.yaml` runs on:

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

The policy lives at `/home/runner/work/proverjay/proverjay/deploy/kyverno/require-signed-proverjay-image.yaml`.

It uses the modern `ImageValidatingPolicy` API and does only two checks for `ghcr.io/h3ow3d/proverjay*` images:

1. `verifyImageSignatures(...)`
2. `verifyAttestationSignatures(...)` for `https://slsa.dev/provenance/v0.2`

## Test Kyverno admission

Apply Kyverno, then apply the policy:

```bash
make install-kyverno
make kyverno-apply-policies
```

Use a known-good release from the current flow and an older release that predates provenance:

```bash
GOOD_IMAGE=ghcr.io/h3ow3d/proverjay:v0.1.10
BAD_IMAGE=ghcr.io/h3ow3d/proverjay:v0.1.4
```

The good image should be admitted:

```bash
kubectl apply --dry-run=server -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: proverjay-good
spec:
  containers:
    - name: app
      image: ${GOOD_IMAGE}
      command: ["sleep", "3600"]
EOF
```

The older image should be denied because it predates the current provenance flow:

```bash
kubectl apply --dry-run=server -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: proverjay-bad
spec:
  containers:
    - name: app
      image: ${BAD_IMAGE}
      command: ["sleep", "3600"]
EOF
```

## Inspect the policy and troubleshoot failures

```bash
kubectl get imagevalidatingpolicy
kubectl describe imagevalidatingpolicy require-signed-proverjay-image
kubectl logs -n kyverno deploy/kyverno-admission-controller
kubectl get events -A | grep -i kyverno
```
