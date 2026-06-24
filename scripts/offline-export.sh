#!/usr/bin/env bash
set -euo pipefail

unset CDPATH

err() {
  echo "[offline-export] $*" >&2
  exit 1
}

command -v oras >/dev/null 2>&1 || err "oras CLI not found. Install ORAS v1.3+ first."

RELEASE_IMAGE="${RELEASE_IMAGE:-ghcr.io/h3ow3d/proverjay:v0.1.10}"
BUNDLE_DIR="${BUNDLE_DIR:-dist}"

image_path="${RELEASE_IMAGE%%[@:]*}"
image_name="${image_path##*/}"

if [[ "$RELEASE_IMAGE" == *@* ]]; then
  image_tag="${RELEASE_IMAGE##*@}"
  image_tag="${image_tag//:/-}"
elif [[ "$RELEASE_IMAGE" == *:* ]]; then
  image_tag="${RELEASE_IMAGE##*:}"
else
  err "RELEASE_IMAGE must include a tag or digest (got: $RELEASE_IMAGE)"
fi

mkdir -p "$BUNDLE_DIR"

bundle_base="${image_name}-${image_tag}.oci-bundle"
bundle_path="${BUNDLE_DIR}/${bundle_base}.tar.gz"
checksum_path="${bundle_path}.sha256"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

layout_dir="$workdir/oci-layout"
payload_dir="$workdir/payload"
mkdir -p "$layout_dir" "$payload_dir"

oci_ref="${image_name}:${image_tag}"

echo "[offline-export] Copying image + referrers from ${RELEASE_IMAGE}"
oras cp --recursive \
  --to-oci-layout \
  --to-oci-layout-path "$layout_dir" \
  "$RELEASE_IMAGE" \
  "$oci_ref"

mv "$layout_dir" "$payload_dir/oci-layout"
cat > "$payload_dir/metadata.env" <<META
SOURCE_IMAGE=${RELEASE_IMAGE}
OCI_REF=${oci_ref}
EXPORT_TIME_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
META

tar -C "$workdir" -czf "$bundle_path" payload
sha256sum "$bundle_path" > "$checksum_path"

echo

echo "[offline-export] Wrote bundle: $bundle_path"
echo "[offline-export] Wrote checksum: $checksum_path"
echo
echo "Next steps:"
echo "  1) Transfer both files to offline environment:"
echo "       $bundle_path"
echo "       $checksum_path"
echo "  2) Verify checksum offline:"
echo "       sha256sum -c $(basename "$checksum_path")"
echo "  3) Import into Harbor:"
echo "       BUNDLE=$(basename "$bundle_path") ./scripts/offline-import-harbor.sh"
