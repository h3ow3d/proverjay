# Harbor offline demo notes

## Demo topology

Online build side:

1. GitHub Actions builds, signs, and attests `ghcr.io/h3ow3d/proverjay` on semver tags.
2. `scripts/offline-export.sh` exports the image plus OCI referrers (Cosign signatures + attestations) into an OCI-layout bundle.

Offline promotion side:

1. Copy the OCI-layout tar bundle into offline environment.
2. Import into Harbor (running via Docker Compose).
3. k3d cluster pulls from Harbor only.
4. Kyverno enforces private-registry source + signature/provenance checks.

The trusted verification key used by the policies lives at `infra/cosign/cosign.pub`.

## Prerequisites

- Docker with Compose plugin
- `openssl`
- `k3d` + `kubectl`

## Step 1 — Generate certs and start Harbor

```bash
make harbor-setup
```

This single command:

1. Generates a self-signed demo CA at `infra/harbor/harbor-ca.crt`
2. Generates a server cert for `harbor.proverjay.test` (signed by that CA)
3. Downloads the Harbor `v2.11.2` online installer into `infra/harbor/installer/`
4. Writes `harbor.yml` from `infra/harbor/harbor.yml.tmpl`
5. Starts Harbor via `docker compose up -d`

To use a different Harbor version: `make harbor-setup HARBOR_VERSION=v2.12.0`

## Step 2 — Add /etc/hosts entry

```bash
echo "127.0.0.1  harbor.proverjay.test" | sudo tee -a /etc/hosts
```

## Step 3 — Create Harbor project

Open `https://harbor.proverjay.test` in a browser (admin / Harbor12345) and create a private project named `proverjay`.

- Keep OCI artifact support enabled (required for signatures and attestations)
- Immutable tags for released tags are recommended

## Step 4 — Create the k3d cluster

```bash
make harbor-cluster-create
```

This detects the Docker bridge gateway IP so that k3d container nodes can reach the Harbor container running on the host, then creates the cluster with the right `extraHosts` entry.

Override auto-detection if needed:

```bash
HARBOR_HOST_IP=172.17.0.1 make harbor-cluster-create
```

## Steps 5–7 — Kyverno, import, deploy

```bash
make install-kyverno
make kyverno-apply-harbor-policies
make offline-import-harbor BUNDLE=dist/proverjay-v0.1.10.oci-bundle.tar.gz
make k8s-deploy-harbor
make harbor-demo-status
```

## Stopping Harbor

```bash
make harbor-down
```

## Hostname/IP assumptions used by this repo

- Harbor DNS name: `harbor.proverjay.test`
- Docker bridge gateway IP: auto-detected by `scripts/harbor-cluster-create.sh`
- k3d Harbor config: `infra/k3d/cluster-harbor-local.yaml` (generated from template)
- Registry config: `infra/k3d/registries-harbor.yaml`

## Harbor CA certificate for k3d

k3d nodes mount `infra/harbor` to `/etc/ssl/harbor`.

The CA is generated automatically by `make harbor-setup` at:

```
infra/harbor/harbor-ca.crt
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

## Cosign key material

- public verification key: `infra/cosign/cosign.pub`
- private signing key: store outside git as the `COSIGN_PRIVATE_KEY` GitHub Actions secret
- optional password: store as `COSIGN_PASSWORD`

When rotating the key pair, update the public key file and redeploy both Kyverno image-validating policies before promoting new releases offline.

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

