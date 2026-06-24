#!/usr/bin/env bash
set -euo pipefail

HARBOR_HOSTNAME="${HARBOR_HOSTNAME:-harbor.proverjay.test}"
HARBOR_PROJECT="${HARBOR_PROJECT:-proverjay}"
IMAGE_NAME="${IMAGE_NAME:-proverjay}"
IMAGE_TAG="${IMAGE_TAG:-af304bfc4159dd945dff0c086a56555f60c556a3}"
HARBOR_USERNAME="${HARBOR_USERNAME:-admin}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-Harbor12345}"

COSIGN_CERT_OIDC_ISSUER="${COSIGN_CERT_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
COSIGN_CERT_IDENTITY="${COSIGN_CERT_IDENTITY:-https://github.com/h3ow3d/proverjay/.github/workflows/ci.yaml@refs/tags/v0.1.11}"

IMAGE_REF="${HARBOR_HOSTNAME}/${HARBOR_PROJECT}/${IMAGE_NAME}:${IMAGE_TAG}"
API_BASE="https://${HARBOR_HOSTNAME}/api/v2.0"
REPO_API="${API_BASE}/projects/${HARBOR_PROJECT}/repositories/${IMAGE_NAME}"

log() {
  echo
  echo "================================================================================"
  echo "$*"
  echo "================================================================================"
}

run() {
  echo
  echo "+ $*"
  "$@"
}

json_pretty() {
  python3 -m json.tool || cat
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require curl
require python3
require oras
require cosign

log "1. Harbor health"
run curl -kfsS "${API_BASE}/health"
echo

log "2. Harbor repository artifact list"
run curl -kfsS \
  -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
  "${REPO_API}/artifacts?with_tag=true&with_label=true&with_scan_overview=true&with_sbom_overview=true&with_signature=true&with_accessory=true" \
  | json_pretty

log "3. Harbor artifact details for tag: ${IMAGE_TAG}"
ARTIFACT_JSON="$(
  curl -kfsS \
    -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
    "${REPO_API}/artifacts/${IMAGE_TAG}?with_tag=true&with_label=true&with_scan_overview=true&with_sbom_overview=true&with_signature=true&with_accessory=true"
)"

printf '%s\n' "$ARTIFACT_JSON" | json_pretty

DIGEST="$(
  printf '%s\n' "$ARTIFACT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("digest",""))'
)"

if [[ -z "$DIGEST" ]]; then
  echo "Could not extract artifact digest from Harbor API response." >&2
  exit 1
fi

echo
echo "Resolved Harbor digest: ${DIGEST}"

log "4. Harbor accessories for digest: ${DIGEST}"
DIGEST_ESCAPED="${DIGEST/:/%3A}"

ACCESSORY_STATUS="$(
  curl -ksS \
    -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
    -o /tmp/harbor-accessories.json \
    -w "%{http_code}" \
    "${REPO_API}/artifacts/${DIGEST_ESCAPED}/accessories"
)"

echo "Accessory endpoint HTTP status: ${ACCESSORY_STATUS}"
cat /tmp/harbor-accessories.json | json_pretty || true

log "5. ORAS discover against Harbor image"
run oras discover \
  --insecure \
  --format json \
  "${IMAGE_REF}" \
  | json_pretty

log "6. ORAS manifest fetch for Harbor image"
run oras manifest fetch \
  --insecure \
  "${IMAGE_REF}" \
  | json_pretty

log "7. Cosign tree against Harbor image"
run cosign tree \
  --allow-insecure-registry \
  "${IMAGE_REF}" \
  || true

log "8. Cosign verify Harbor image using keyless GitHub Actions identity"
run cosign verify \
  --allow-insecure-registry \
  --certificate-oidc-issuer "${COSIGN_CERT_OIDC_ISSUER}" \
  --certificate-identity "${COSIGN_CERT_IDENTITY}" \
  "${IMAGE_REF}"

log "9. Current Kubernetes deployment image, if deployed"
kubectl get deploy -n "${HARBOR_PROJECT}" -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' 2>/dev/null || true

log "Diagnosis complete"
echo "Image ref: ${IMAGE_REF}"
echo "Digest:    ${DIGEST}"
