#!/usr/bin/env bash
set -euo pipefail

RELEASE_IMAGE="${RELEASE_IMAGE:-ghcr.io/h3ow3d/proverjay:af304bfc4159dd945dff0c086a56555f60c556a3}"
SOURCE_URI="${SOURCE_URI:-github.com/h3ow3d/proverjay}"
SOURCE_TAG="${SOURCE_TAG:-v0.1.11}"

COSIGN_CERT_OIDC_ISSUER="${COSIGN_CERT_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
COSIGN_CERT_IDENTITY="${COSIGN_CERT_IDENTITY:-https://github.com/h3ow3d/proverjay/.github/workflows/ci.yaml@refs/tags/v0.1.11}"

log() { echo "[prove-ghcr-release] $*"; }
err() { echo "[prove-ghcr-release] ERROR: $*" >&2; exit 1; }

command -v cosign >/dev/null 2>&1 || err "cosign is required"
command -v slsa-verifier >/dev/null 2>&1 || err "slsa-verifier is required"
command -v crane >/dev/null 2>&1 || err "crane is required"

if [[ -z "${GH_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  log "GH_TOKEN not set; using token from gh CLI."
  export GH_TOKEN="$(gh auth token)"
fi

log "Release image:"
log "  ${RELEASE_IMAGE}"

log "Expected signing identity:"
log "  issuer:  ${COSIGN_CERT_OIDC_ISSUER}"
log "  subject: ${COSIGN_CERT_IDENTITY}"

log "Expected SLSA source:"
log "  source-uri: ${SOURCE_URI}"
log "  source-tag: ${SOURCE_TAG}"

log "Resolving immutable image digest..."
IMAGE_DIGEST="$(crane digest "${RELEASE_IMAGE}")"
IMAGE_REPO="${RELEASE_IMAGE%:*}"
IMAGE_BY_DIGEST="${IMAGE_REPO}@${IMAGE_DIGEST}"

log "Resolved immutable image:"
log "  ${IMAGE_BY_DIGEST}"

log "Verifying keyless Cosign image signature..."
cosign verify \
  --certificate-oidc-issuer "${COSIGN_CERT_OIDC_ISSUER}" \
  --certificate-identity "${COSIGN_CERT_IDENTITY}" \
  "${RELEASE_IMAGE}"

log "Verifying SLSA provenance..."
slsa-verifier verify-image \
  "${IMAGE_BY_DIGEST}" \
  --source-uri "${SOURCE_URI}" \
  --source-tag "${SOURCE_TAG}"

log "Local proof complete."
log ""
log "Proved:"
log "  - image signature is valid"
log "  - signing identity is the expected GitHub Actions workflow"
log "  - image digest is immutable: ${IMAGE_DIGEST}"
log "  - SLSA provenance matches expected source repo/tag"
