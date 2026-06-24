#!/usr/bin/env bash
set -euo pipefail

# offline-export.sh — export an OCI image plus referrers from a registry into
# a compressed OCI layout bundle.
#
# Env vars:
#   RELEASE_IMAGE — source image, e.g. ghcr.io/h3ow3d/proverjay:<tag>
#   BUNDLE_DIR    — output directory, default: dist

RELEASE_IMAGE="${RELEASE_IMAGE:-ghcr.io/h3ow3d/proverjay:af304bfc4159dd945dff0c086a56555f60c556a3}"
BUNDLE_DIR="${BUNDLE_DIR:-dist}"

log() { echo "[offline-export] $*"; }
err() { echo "[offline-export] ERROR: $*" >&2; exit 1; }

command -v oras >/dev/null 2>&1 || err "oras CLI not found. Install ORAS v1.3+ first."
command -v tar  >/dev/null 2>&1 || err "tar is required"

case "$RELEASE_IMAGE" in
  *@sha256:*)
    err "RELEASE_IMAGE must be tag-based for this demo bundle path, not digest-based. Got: $RELEASE_IMAGE"
    ;;
  *:*)
    ;;
  *)
    err "RELEASE_IMAGE must include a tag. Got: $RELEASE_IMAGE"
    ;;
esac

IMAGE_REPO="${RELEASE_IMAGE%:*}"
IMAGE_TAG="${RELEASE_IMAGE##*:}"
IMAGE_NAME="${IMAGE_REPO##*/}"

mkdir -p "$BUNDLE_DIR"

BUNDLE="${BUNDLE_DIR}/${IMAGE_NAME}-${IMAGE_TAG}.oci-bundle.tar.gz"
WORK_DIR="$(mktemp -d)"
LAYOUT_DIR="${WORK_DIR}/layout"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

log "Source image: $RELEASE_IMAGE"
log "Image name:   $IMAGE_NAME"
log "Image tag:    $IMAGE_TAG"
log "Bundle:       $BUNDLE"
log "Copying image plus referrers into OCI layout..."

oras cp \
  --recursive \
  --to-oci-layout \
  --no-tty \
  "$RELEASE_IMAGE" \
  "${LAYOUT_DIR}:${IMAGE_TAG}"

log "Creating compressed bundle..."
tar -czf "$BUNDLE" -C "$WORK_DIR" layout

log "Export complete:"
log "  $BUNDLE"
