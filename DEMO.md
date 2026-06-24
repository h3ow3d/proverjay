# Demo overview

This demo shows a complete secure software delivery flow for a container image. 
We will create a release tag, allow GitHub Actions to build the image, sign it 
keylessly with Cosign, generate and verify SLSA provenance, then promote the 
image and its supply-chain evidence into Harbor. Finally, we will use Kyverno 
admission policies in Kubernetes to prove that only images from Harbor with the 
expected GitHub Actions signature and SLSA attestation are allowed to run.

The demo proves three controls:

1. **Source control** — workloads must use images from our trusted Harbor 
  registry.
2. **Signature control** — images must be signed by the expected GitHub Actions 
  workflow identity.
3. **Provenance control** — images must carry SLSA provenance showing the 
  expected repository, tag, workflow, and SLSA builder.

We will then intentionally try two invalid deployments: one from outside Harbor, 
and one from Harbor without the required signature and attestation. Both should 
be blocked before the Pod is admitted to the cluster.

# Demo 

1. Create a new release tag

```bash
git tag v0.1.19
git push origin v0.1.19
```

```bash
# ------------------------------------------------------------------------------
# Release selection
# ------------------------------------------------------------------------------

export NEW_TAG=v0.1.19
# The release tag being demonstrated.

export RELEASE_TAG="$(git rev-parse "${NEW_TAG}^{commit}")"
# The exact Git commit SHA behind the release tag.

# ------------------------------------------------------------------------------
# Source image in GHCR
# ------------------------------------------------------------------------------

export RELEASE_REPO="ghcr.io/h3ow3d/proverjay"
# The source GHCR image repository.

export RELEASE_IMAGE="${RELEASE_REPO}:${RELEASE_TAG}"
# The source GHCR image tagged by commit SHA.

export IMAGE_DIGEST="$(crane digest "${RELEASE_IMAGE}")"
# The immutable image digest used for signing, attestation, and promotion.

export RELEASE_IMAGE_BY_DIGEST="${RELEASE_REPO}@${IMAGE_DIGEST}"
# The immutable GHCR image reference.

# ------------------------------------------------------------------------------
# Destination image in Harbor
# ------------------------------------------------------------------------------

export HARBOR_REGISTRY=harbor.proverjay.test:18443
# The local Harbor registry endpoint.

export HARBOR_REPO="${HARBOR_REGISTRY}/proverjay/proverjay"
# The destination Harbor image repository.

export HARBOR_IMAGE="${HARBOR_REPO}:${RELEASE_TAG}"
# The Harbor image tagged by the same commit SHA.

export HARBOR_IMAGE_BY_DIGEST="${HARBOR_REPO}@${IMAGE_DIGEST}"
# The immutable Harbor image reference.

# ------------------------------------------------------------------------------
# Cosign / GitHub OIDC identity
# ------------------------------------------------------------------------------

export COSIGN_ISSUER="https://token.actions.githubusercontent.com"
# The expected GitHub Actions OIDC issuer.

export GITHUB_IDENTITY="https://github.com/h3ow3d/proverjay/.github/workflows/ci.yaml@refs/tags/${NEW_TAG}"
# The expected GitHub Actions workflow identity that signed the image and attestation.
```

2. Show GitHub Actions produced:
   - container image
   - Cosign keyless signature
   - SLSA provenance
   - Cosign-readable SLSA attestation

```bash
cosign tree --allow-insecure-registry "${RELEASE_IMAGE_BY_DIGEST}"

# Verify the original SLSA generator provenance for this image digest.
slsa-verifier verify-image \
  "${RELEASE_IMAGE_BY_DIGEST}" \
  --source-uri github.com/h3ow3d/proverjay \
  --source-tag "${NEW_TAG}" \
  --print-provenance \
  > "/tmp/proverjay-${NEW_TAG}-slsa-provenance.json"

jq '{
  predicateType,
  subject,
  builder: .predicate.builder,
  buildType: .predicate.buildType,
  invocation: .predicate.invocation.configSource
}' "/tmp/proverjay-${NEW_TAG}-slsa-provenance.json"

# Verify the Cosign keyless image signature.
cosign verify \
  --certificate-oidc-issuer "${COSIGN_ISSUER}" \
  --certificate-identity "${GITHUB_IDENTITY}" \
  "${RELEASE_IMAGE_BY_DIGEST}"

# Verify the Cosign-readable SLSA attestation attached to the image.
cosign verify-attestation \
  --type slsaprovenance \
  --certificate-oidc-issuer "${COSIGN_ISSUER}" \
  --certificate-identity "${GITHUB_IDENTITY}" \
  "${RELEASE_IMAGE_BY_DIGEST}" \
  | jq -r '.payload | @base64d | fromjson | {
      predicateType,
      subject,
      builder: .predicate.builder,
      buildType: .predicate.buildType,
      invocation: .predicate.invocation.configSource
    }'
```

3. Promote image + signature + attestation to Harbor

```bash
oras copy \
  --recursive \
  --to-insecure \
  "${RELEASE_IMAGE_BY_DIGEST}" \
  "${HARBOR_IMAGE}"

export ATT_TAG="sha256-${IMAGE_DIGEST#sha256:}.att"

crane copy \
  --insecure \
  "${RELEASE_REPO}:${ATT_TAG}" \
  "${HARBOR_REPO}:${ATT_TAG}"
```

4. Prove Harbor contains:
   - image
   - signature
   - SLSA attestation

```bash
cosign tree --allow-insecure-registry "${HARBOR_IMAGE}"

cosign verify \
  --allow-insecure-registry \
  --certificate-oidc-issuer "${COSIGN_ISSUER}" \
  --certificate-identity "${GITHUB_IDENTITY}" \
  "${HARBOR_IMAGE_BY_DIGEST}"

cosign verify-attestation \
  --allow-insecure-registry \
  --type slsaprovenance \
  --certificate-oidc-issuer "${COSIGN_ISSUER}" \
  --certificate-identity "${GITHUB_IDENTITY}" \
  "${HARBOR_IMAGE_BY_DIGEST}"
```

5. Deploy valid Harbor image
   - passes

```bash
kubectl run kyverno-positive-test \
  --namespace proverjay \
  --image="${HARBOR_IMAGE}" \
  --restart=Never \
  --dry-run=server \
  -o yaml
```

6. Deploy non-Harbor image
   - blocked

```bash
kubectl run kyverno-negative-source-test \
  --namespace proverjay \
  --image=nginx:latest \
  --restart=Never \
  --dry-run=server \
  -o yaml
```

7. Deploy Harbor image without signature/attestation
   - blocked

```bash
crane copy \
  --insecure \
  alpine:3.20 \
  "${HARBOR_REGISTRY}/proverjay/proverjay:unsigned-test"

kubectl run kyverno-negative-signature-test \
  --namespace proverjay \
  --image="${HARBOR_REGISTRY}/proverjay/proverjay:unsigned-test" \
  --restart=Never \
  --dry-run=server \
  -o yaml
```

8. Show policies explain why

