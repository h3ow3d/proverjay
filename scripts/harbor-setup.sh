#!/usr/bin/env bash
set -euo pipefail

# harbor-setup.sh — generate self-signed TLS certs, download the Harbor online
# installer, configure it, and start Harbor via Docker Compose.
#
# Env vars (all optional):
#   HARBOR_VERSION   — Harbor release to use (default: v2.11.2)
#   HARBOR_HOSTNAME  — hostname for Harbor (default: harbor.proverjay.test)

HARBOR_VERSION="${HARBOR_VERSION:-v2.11.2}"
HARBOR_HOSTNAME="${HARBOR_HOSTNAME:-harbor.proverjay.test}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARBOR_INFRA_DIR="${REPO_ROOT}/infra/harbor"
CERTS_DIR="${HARBOR_INFRA_DIR}/certs"
DATA_DIR="${HARBOR_INFRA_DIR}/data"
INSTALLER_DIR="${HARBOR_INFRA_DIR}/installer"
HARBOR_INSTALL_DIR="${INSTALLER_DIR}/harbor"

log()  { echo "[harbor-setup] $*"; }
err()  { echo "[harbor-setup] ERROR: $*" >&2; exit 1; }

command -v docker  >/dev/null 2>&1 || err "docker is required"
command -v openssl >/dev/null 2>&1 || err "openssl is required"
command -v curl    >/dev/null 2>&1 || err "curl is required"

mkdir -p "$CERTS_DIR" "$DATA_DIR" "$INSTALLER_DIR"

# ---------------------------------------------------------------------------
# TLS certificates
# ---------------------------------------------------------------------------

if [[ ! -f "${HARBOR_INFRA_DIR}/harbor-ca.crt" || ! -f "${CERTS_DIR}/ca.key" ]]; then
  log "Generating self-signed demo CA..."
  openssl genrsa -out "${CERTS_DIR}/ca.key" 4096 2>/dev/null
  openssl req -x509 -new -nodes \
    -key "${CERTS_DIR}/ca.key" \
    -sha256 -days 3650 \
    -subj "/CN=harbor-demo-ca/O=proverjay-demo" \
    -out "${HARBOR_INFRA_DIR}/harbor-ca.crt"
  log "CA cert written to: infra/harbor/harbor-ca.crt"
fi

if [[ ! -f "${CERTS_DIR}/harbor.crt" || ! -f "${CERTS_DIR}/harbor.key" ]]; then
  log "Generating server cert for ${HARBOR_HOSTNAME}..."

  openssl genrsa -out "${CERTS_DIR}/harbor.key" 2048 2>/dev/null

  openssl req -new \
    -key "${CERTS_DIR}/harbor.key" \
    -subj "/CN=${HARBOR_HOSTNAME}" \
    -out "${CERTS_DIR}/harbor.csr"

  cat > "${CERTS_DIR}/harbor.ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names

[alt_names]
DNS.1=${HARBOR_HOSTNAME}
IP.1=127.0.0.1
EOF

  openssl x509 -req \
    -in "${CERTS_DIR}/harbor.csr" \
    -CA "${HARBOR_INFRA_DIR}/harbor-ca.crt" \
    -CAkey "${CERTS_DIR}/ca.key" \
    -CAcreateserial \
    -out "${CERTS_DIR}/harbor.crt" \
    -days 3650 -sha256 \
    -extfile "${CERTS_DIR}/harbor.ext" 2>/dev/null

  log "Server cert written to: infra/harbor/certs/harbor.crt"
fi

# ---------------------------------------------------------------------------
# Harbor installer
# ---------------------------------------------------------------------------

if [[ ! -d "$HARBOR_INSTALL_DIR" ]]; then
  pkg="harbor-online-installer-${HARBOR_VERSION}.tgz"
  url="https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/${pkg}"
  log "Downloading Harbor ${HARBOR_VERSION} online installer..."
  curl -fsSL --progress-bar -o "${INSTALLER_DIR}/${pkg}" "$url"
  tar -xzf "${INSTALLER_DIR}/${pkg}" -C "$INSTALLER_DIR"
  log "Installer extracted to: ${HARBOR_INSTALL_DIR}"
fi

# ---------------------------------------------------------------------------
# harbor.yml from template
# ---------------------------------------------------------------------------

log "Writing harbor.yml..."
sed \
  -e "s|__HARBOR_CERT_PATH__|${CERTS_DIR}/harbor.crt|g" \
  -e "s|__HARBOR_KEY_PATH__|${CERTS_DIR}/harbor.key|g" \
  -e "s|__HARBOR_DATA_DIR__|${DATA_DIR}|g" \
  "${HARBOR_INFRA_DIR}/harbor.yml.tmpl" \
  > "${HARBOR_INSTALL_DIR}/harbor.yml"

# ---------------------------------------------------------------------------
# Start Harbor
# ---------------------------------------------------------------------------

log "Running Harbor prepare..."
cd "$HARBOR_INSTALL_DIR"
# goharbor/prepare only publishes linux/amd64 images; force that platform so
# the prepare step works on arm64 hosts (Apple Silicon) via Rosetta/QEMU.
DOCKER_DEFAULT_PLATFORM=linux/amd64 ./prepare

log "Starting Harbor..."
docker compose up -d

log ""
log "Harbor is up at https://${HARBOR_HOSTNAME}"
log "  username: admin"
log "  password: Harbor12345"
log ""
log "Add to /etc/hosts if not already present:"
log "  127.0.0.1  ${HARBOR_HOSTNAME}"
log ""
log "Next steps:"
log "  1) Add the /etc/hosts entry above (requires sudo)"
log "  2) Create the Harbor project:  Harbor UI -> Projects -> New Project -> proverjay (private)"
log "  3) Create the k3d cluster:     make harbor-cluster-create"
