#!/usr/bin/env bash
set -euo pipefail

unset CDPATH

err() {
  echo "[offline-import-harbor] $*" >&2
  exit 1
}

command -v oras >/dev/null 2>&1 || err "oras CLI not found. Install ORAS v1.3+ first."

BUNDLE="${BUNDLE:-}"
HARBOR_HOSTNAME="${HARBOR_HOSTNAME:-harbor.proverjay.test}"
HARBOR_PROJECT="${HARBOR_PROJECT:-proverjay}"
IMAGE_NAME="${IMAGE_NAME:-proverjay}"
IMAGE_TAG="${IMAGE_TAG:-}"

[[ -n "$BUNDLE" ]] || err "BUNDLE is required (path to .oci-bundle.tar.gz)"
[[ -f "$BUNDLE" ]] || err "Bundle not found: $BUNDLE"

if [[ -z "$IMAGE_TAG" ]]; then
  bundle_file="$(basename "$BUNDLE")"
  if [[ "$bundle_file" == *.oci-bundle.tar.gz ]]; then
    stem="${bundle_file%.oci-bundle.tar.gz}"
    IMAGE_TAG="${stem##*-}"
  fi
fi
[[ -n "$IMAGE_TAG" ]] || IMAGE_TAG="v0.1.10"

if [[ ! -f "$HOME/.docker/config.json" ]] || ! grep -q "\"$HARBOR_HOSTNAME\"" "$HOME/.docker/config.json"; then
  err "No login entry found for ${HARBOR_HOSTNAME}. Run: oras login ${HARBOR_HOSTNAME}"
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pubkey_path="${repo_root}/infra/cosign/cosign.pub"

tar -xzf "$BUNDLE" -C "$workdir"
layout_dir="$workdir/payload/oci-layout"
metadata_file="$workdir/payload/metadata.env"

[[ -d "$layout_dir" ]] || err "Invalid bundle: missing payload/oci-layout"

source_ref="${IMAGE_NAME}:${IMAGE_TAG}"
if [[ -f "$metadata_file" ]]; then
  # shellcheck disable=SC1090
  source "$metadata_file"
  if [[ -n "${OCI_REF:-}" ]]; then
    source_ref="$OCI_REF"
  fi
fi

target_ref="${HARBOR_HOSTNAME}/${HARBOR_PROJECT}/${IMAGE_NAME}:${IMAGE_TAG}"

echo "[offline-import-harbor] Importing ${source_ref} to ${target_ref}"
oras cp --recursive \
  --from-oci-layout \
  --from-oci-layout-path "$layout_dir" \
  "$source_ref" \
  "$target_ref"

echo

echo "[offline-import-harbor] Import completed: ${target_ref}"
echo
echo "Suggested verification commands:"
echo "  cosign verify --key ${pubkey_path} \\"
echo "    ${target_ref}"
echo "  cosign verify-attestation --type slsaprovenance --key ${pubkey_path} \\"
echo "    ${target_ref}"
