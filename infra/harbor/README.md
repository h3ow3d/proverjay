# Harbor offline demo notes

## Demo topology

Online build side:

1. GitHub Actions builds, signs, and attests `ghcr.io/h3ow3d/proverjay` on semver tags.
2. `scripts/offline-export.sh` exports the image plus OCI referrers (Cosign signatures + attestations) into an OCI-layout bundle.

Offline promotion side:

1. Copy the OCI-layout tar bundle into offline environment.
2. Import into Harbor (running in a libvirt VM).
3. k3d cluster pulls from Harbor only.
4. Kyverno enforces private-registry source + signature/provenance checks.

## Harbor in a libvirt VM (high-level)

1. Create VM (Ubuntu/Rocky/etc) on the libvirt network.
2. Install Docker + Docker Compose plugin.
3. Install Harbor using official installer in HTTPS mode.
4. Give Harbor a stable hostname and cert, for example:
   - hostname: `harbor.proverjay.test`
   - VM IP: `192.168.122.10`

This repo assumes those values by default; adjust scripts/Make variables if different.

## Hostname/IP assumptions used by this repo

- Harbor DNS name: `harbor.proverjay.test`
- Example VM IP: `192.168.122.10`
- k3d Harbor config file: `infra/k3d/cluster-harbor.yaml`
- Registry config file: `infra/k3d/registries-harbor.yaml`

Update both files if your Harbor hostname/IP is different.

## Harbor CA certificate for k3d

k3d nodes mount `infra/harbor` to `/etc/ssl/harbor`.

Place Harbor CA PEM at:

`infra/harbor/harbor-ca.crt`

Typical export from Harbor VM:

```bash
scp harbor-vm:/path/to/ca.crt /path/to/proverjay/infra/harbor/harbor-ca.crt
```

## Login commands

```bash
# Harbor
oras login harbor.proverjay.test
cosign login harbor.proverjay.test
docker login harbor.proverjay.test

# GHCR (online side, if needed)
oras login ghcr.io
```

## Create Harbor project

```bash
# Harbor UI: Projects -> New Project -> Name: proverjay
```

Project settings recommended for this demo:

- private project
- immutable tags for released tags (recommended)
- disallow vulnerable images optional for demo
- keep OCI artifact support enabled (for signatures/attestations)

## Import flow

```bash
# online side
make offline-export RELEASE_IMAGE=ghcr.io/h3ow3d/proverjay:v0.1.10

# transfer dist/*.oci-bundle.tar.gz and .sha256

# offline side
make offline-import-harbor \
  BUNDLE=dist/proverjay-v0.1.10.oci-bundle.tar.gz \
  HARBOR_HOSTNAME=harbor.proverjay.test \
  HARBOR_PROJECT=proverjay \
  HARBOR_IMAGE=proverjay \
  HARBOR_TAG=v0.1.10
```
