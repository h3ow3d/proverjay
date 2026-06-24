#!/usr/bin/env bash
set -euo pipefail

# offline-import-harbor.sh — import an OCI layout bundle into local Harbor.
#
# Env vars:
#   BUNDLE           — bundle path, e.g. dist/proverjay-<tag>.oci-bundle.tar.gz
#   HARBOR_HOSTNAME  — Harbor hostname, default: harbor.proverjay.test
#   HARBOR_PROJECT   — Harbor project, default: proverjay
#   IMAGE_NAME       — destination image name, default: proverjay
#   IMAGE_TAG        — destination image tag
#   HARBOR_USERNAME  — Harbor username, default: admin
#   HARBOR_PASSWORD  — Harbor password, default: Harbor12345

HARBOR_HOSTNAME="${HARBOR_HOSTNAME:-harbor.proverjay.test}"
HARBOR_PROJECT="${HARBOR_PROJECT:-proverjay}"
IMAGE_NAME="${IMAGE_NAME:-proverjay}"
IMAGE_TAG="${IMAGE_TAG:-}"
HARBOR_USERNAME="${HARBOR_USERNAME:-admin}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-Harbor12345}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARBOR_CA_FILE="${REPO_ROOT}/infra/harbor/harbor-ca.crt"

log() { echo "[offline-import-harbor] $*"; }
err() { echo "[offline-import-harbor] ERROR: $*" >&2; exit 1; }

command -v oras >/dev/null 2>&1 || err "oras CLI not found. Install ORAS v1.3+ first."
command -v tar  >/dev/null 2>&1 || err "tar is required."
command -v curl >/dev/null 2>&1 || err "curl is required."

[[ -n "${BUNDLE:-}" ]] || err "BUNDLE is required."
[[ -f "$BUNDLE" ]] || err "Bundle not found: $BUNDLE"
[[ -n "$IMAGE_TAG" ]] || err "IMAGE_TAG is required."

DEST_IMAGE="${HARBOR_HOSTNAME}/${HARBOR_PROJECT}/${IMAGE_NAME}:${IMAGE_TAG}"

WORK_DIR="$(mktemp -d)"
LAYOUT_DIR="${WORK_DIR}/layout"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

log "Bundle:      $BUNDLE"
log "Destination: $DEST_IMAGE"

log "Checking Harbor health..."
curl -kfsS "https://${HARBOR_HOSTNAME}/api/v2.0/health" >/dev/null \
  || err "Harbor is not reachable at https://${HARBOR_HOSTNAME}"

log "Ensuring Harbor project exists: ${HARBOR_PROJECT}"

PROJECT_STATUS="$(
  curl -ksS \
    -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
    -o /dev/null \
    -w "%{http_code}" \
    "https://${HARBOR_HOSTNAME}/api/v2.0/projects/${HARBOR_PROJECT}"
)"

if [[ "$PROJECT_STATUS" == "404" ]]; then
  log "Creating Harbor project: ${HARBOR_PROJECT}"
  curl -kfsS \
    -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
    -H "Content-Type: application/json" \
    -X POST \
    "https://${HARBOR_HOSTNAME}/api/v2.0/projects" \
    -d "{\"project_name\":\"${HARBOR_PROJECT}\",\"public\":true}" \
    >/dev/null
elif [[ "$PROJECT_STATUS" == "200" ]]; then
  log "Harbor project already exists: ${HARBOR_PROJECT}"
else
  err "Unexpected Harbor project lookup status: ${PROJECT_STATUS}"
fi

log "Logging ORAS into Harbor..."

if [[ -f "$HARBOR_CA_FILE" ]]; then
  if printf '%s' "$HARBOR_PASSWORD" | oras login \
      --ca-file "$HARBOR_CA_FILE" \
      --username "$HARBOR_USERNAME" \
      --password-stdin \
      "$HARBOR_HOSTNAME"; then
    ORAS_TLS_FLAGS=(--to-ca-file "$HARBOR_CA_FILE")
  else
    log "ORAS login with CA failed; retrying with --insecure for local demo Harbor..."
    printf '%s' "$HARBOR_PASSWORD" | oras login \
      --insecure \
      --username "$HARBOR_USERNAME" \
      --password-stdin \
      "$HARBOR_HOSTNAME"
    ORAS_TLS_FLAGS=(--to-insecure)
  fi
else
  log "Harbor CA file not found; using --insecure for local demo Harbor..."
  printf '%s' "$HARBOR_PASSWORD" | oras login \
    --insecure \
    --username "$HARBOR_USERNAME" \
    --password-stdin \
    "$HARBOR_HOSTNAME"
  ORAS_TLS_FLAGS=(--to-insecure)
fi

log "Extracting OCI layout bundle..."
tar -xzf "$BUNDLE" -C "$WORK_DIR"

[[ -d "$LAYOUT_DIR" ]] || err "Bundle did not contain expected OCI layout directory: layout"

log "Copying OCI layout plus referrers into Harbor..."

oras cp \
  --recursive \
  --from-oci-layout \
  --no-tty \
  "${ORAS_TLS_FLAGS[@]}" \
  "${LAYOUT_DIR}:${IMAGE_TAG}" \
  "$DEST_IMAGE"

log "Import complete:"
log "  $DEST_IMAGE"
