# proverjay

A small Go app for learning hardened software supply chains.

## Current checkpoint

The project currently demonstrates:

- Go test CI
- Docker image build
- GHCR publish only on SemVer tags
- keyless Sigstore/cosign image signing
- SLSA provenance generation
- local k3d deployment by image digest

## Verify release artifact

```bash
make verify-image
make verify-provenance
