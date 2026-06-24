# Cosign release key

This directory contains the public key trusted by local verification commands and Kyverno policies.

## Files

- `cosign.pub`: public verification key committed to this repository

Do not store the matching private key in git. Keep it in GitHub Actions as the `COSIGN_PRIVATE_KEY` secret and, if applicable, store the password in `COSIGN_PASSWORD`.

## Rotation

1. Generate a new key pair with `cosign generate-key-pair`.
2. Replace `cosign.pub` in this directory.
3. Update the inline public key in:
   - `deploy/kyverno/require-signed-proverjay-image.yaml`
   - `deploy/kyverno/require-signed-proverjay-harbor-image.yaml`
4. Deploy the updated policies before cutting new release tags.

Releases signed with the older keyless flow will fail the current key-based policies.
