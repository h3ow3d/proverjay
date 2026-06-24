# Cosign signing

This repository uses Sigstore's keyless signing flow. Images pushed on semver tags are signed by
the GitHub Actions release workflow using the ambient OIDC identity — no private key or secret is
required.

## Verification identity

- **OIDC issuer**: `https://token.actions.githubusercontent.com`
- **Subject pattern**: `https://github.com/h3ow3d/proverjay/.github/workflows/ci.yaml@refs/tags/v.*`

Signatures and attestations are recorded in the Sigstore transparency log at
`https://rekor.sigstore.dev`.

## Legacy key pair

`cosign.pub` is the public half of the key pair that was used for signing between the initial
key-pair migration and the revert to keyless signing. It is kept for reference only; it is no longer
trusted by the Kyverno policies or the Makefile verification targets.
