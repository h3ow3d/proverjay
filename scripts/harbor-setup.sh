#!/usr/bin/env bash
set -euo pipefail

# harbor-setup.sh — download Harbor, generate local demo TLS certs,
# render harbor.yml, patch Harbor's prepare script for macOS Docker mounts,
# run Harbor prepare, and start Harbor with Docker Compose.
#
# Env vars:
#   HARBOR_VERSION   — Harbor release to use, e.g. v2.11.2
#   HARBOR_HOSTNAME  — local hostname for Harbor
#
# This is intended for a local Docker Compose demo.

HARBOR_VERSION="${HARBOR_VERSION:-v2.11.2}"
HARBOR_HOSTNAME="${HARBOR_HOSTNAME:-harbor.proverjay.test}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARBOR_INFRA_DIR="${REPO_ROOT}/infra/harbor"
SOURCE_CERTS_DIR="${HARBOR_INFRA_DIR}/certs"
DATA_DIR="${HARBOR_INFRA_DIR}/data"
INSTALLER_DIR="${HARBOR_INFRA_DIR}/installer"
HARBOR_INSTALL_DIR="${INSTALLER_DIR}/harbor"
INSTALL_CERTS_DIR="${HARBOR_INSTALL_DIR}/certs"

HARBOR_TEMPLATE="${HARBOR_INFRA_DIR}/harbor.yml.tmpl"
HARBOR_CONFIG="${HARBOR_INSTALL_DIR}/harbor.yml"

log() { echo "[harbor-setup] $*"; }
err() { echo "[harbor-setup] ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "$1 is required"
}

require_cmd docker
require_cmd openssl
require_cmd curl
require_cmd tar
require_cmd sed
require_cmd python3

mkdir -p "$SOURCE_CERTS_DIR" "$DATA_DIR" "$INSTALLER_DIR"

[[ -f "$HARBOR_TEMPLATE" ]] || err "Missing template: $HARBOR_TEMPLATE"

# ---------------------------------------------------------------------------
# Harbor installer
# ---------------------------------------------------------------------------

if [[ ! -x "${HARBOR_INSTALL_DIR}/prepare" ]]; then
  pkg="harbor-online-installer-${HARBOR_VERSION}.tgz"
  url="https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/${pkg}"

  log "Downloading Harbor ${HARBOR_VERSION} online installer..."
  rm -rf "$HARBOR_INSTALL_DIR"
  curl -fsSL --progress-bar -o "${INSTALLER_DIR}/${pkg}" "$url"

  log "Extracting Harbor installer..."
  tar -xzf "${INSTALLER_DIR}/${pkg}" -C "$INSTALLER_DIR"

  [[ -x "${HARBOR_INSTALL_DIR}/prepare" ]] || err "Harbor prepare script not found after extraction"
  log "Installer extracted to: ${HARBOR_INSTALL_DIR}"
else
  log "Using existing Harbor installer: ${HARBOR_INSTALL_DIR}"
fi

mkdir -p "$INSTALL_CERTS_DIR"

# ---------------------------------------------------------------------------
# Patch Harbor prepare hostfs mount
# ---------------------------------------------------------------------------

# Harbor's own ./prepare script normally mounts:
#
#   -v /:/hostfs
#
# On Docker Desktop for macOS, that broad root bind mount can fail to expose
# /Users/... reliably to the prepare container. We patch it to mount this repo
# directly at the exact /hostfs path Harbor later expects.
#
# Example:
#   /Users/samholden/Git/proverjay
# becomes:
#   /hostfs/Users/samholden/Git/proverjay

log "Patching Harbor prepare hostfs mount..."

python3 - "${HARBOR_INSTALL_DIR}/prepare" "$REPO_ROOT" <<'PY'
from pathlib import Path
import sys

prepare = Path(sys.argv[1])
repo_root = sys.argv[2]

text = prepare.read_text()

old = "-v /:/hostfs " + "\\"
new = f"-v {repo_root}:/hostfs{repo_root} " + "\\"

if old in text:
    text = text.replace(old, new)
    prepare.write_text(text)
elif new in text:
    pass
else:
    raise SystemExit(
        "Could not find expected Harbor prepare hostfs mount. "
        "Expected either the original '-v /:/hostfs \\' or the patched repo mount."
    )
PY

chmod +x "${HARBOR_INSTALL_DIR}/prepare"

# ---------------------------------------------------------------------------
# TLS certificates
# ---------------------------------------------------------------------------

CA_KEY="${SOURCE_CERTS_DIR}/ca.key"
CA_CRT="${HARBOR_INFRA_DIR}/harbor-ca.crt"
SERVER_KEY="${SOURCE_CERTS_DIR}/harbor.key"
SERVER_CSR="${SOURCE_CERTS_DIR}/harbor.csr"
SERVER_CRT="${SOURCE_CERTS_DIR}/harbor.crt"
SERVER_EXT="${SOURCE_CERTS_DIR}/harbor.ext"

if [[ ! -f "$CA_CRT" || ! -f "$CA_KEY" ]]; then
  log "Generating self-signed demo CA..."

  openssl genrsa -out "$CA_KEY" 4096 2>/dev/null

  openssl req -x509 -new -nodes \
    -key "$CA_KEY" \
    -sha256 \
    -days 3650 \
    -subj "/CN=harbor-demo-ca/O=proverjay-demo" \
    -out "$CA_CRT"

  log "CA cert written to: infra/harbor/harbor-ca.crt"
else
  log "Using existing demo CA"
fi

if [[ ! -f "$SERVER_CRT" || ! -f "$SERVER_KEY" ]]; then
  log "Generating server cert for ${HARBOR_HOSTNAME}..."

  openssl genrsa -out "$SERVER_KEY" 2048 2>/dev/null

  openssl req -new \
    -key "$SERVER_KEY" \
    -subj "/CN=${HARBOR_HOSTNAME}" \
    -out "$SERVER_CSR"

  cat > "$SERVER_EXT" <<EOF
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
    -in "$SERVER_CSR" \
    -CA "$CA_CRT" \
    -CAkey "$CA_KEY" \
    -CAcreateserial \
    -out "$SERVER_CRT" \
    -days 3650 \
    -sha256 \
    -extfile "$SERVER_EXT" 2>/dev/null

  log "Server cert written to: infra/harbor/certs/harbor.crt"
else
  log "Using existing server cert"
fi

# Copy certs into the Harbor installer directory.
# This keeps certs under Harbor's prepare base directory, which simplifies
# how Harbor resolves them inside its prepare container.

log "Copying certs into Harbor installer directory..."

cp "$SERVER_CRT" "${INSTALL_CERTS_DIR}/harbor.crt"
cp "$SERVER_KEY" "${INSTALL_CERTS_DIR}/harbor.key"
cp "$CA_CRT" "${INSTALL_CERTS_DIR}/harbor-ca.crt"

chmod 600 "${INSTALL_CERTS_DIR}/harbor.key"

[[ -s "${INSTALL_CERTS_DIR}/harbor.crt" ]] || err "Installer cert missing or empty"
[[ -s "${INSTALL_CERTS_DIR}/harbor.key" ]] || err "Installer key missing or empty"

# ---------------------------------------------------------------------------
# harbor.yml from template
# ---------------------------------------------------------------------------

log "Writing harbor.yml..."

sed \
  -e "s|__HARBOR_CERT_PATH__|${INSTALL_CERTS_DIR}/harbor.crt|g" \
  -e "s|__HARBOR_KEY_PATH__|${INSTALL_CERTS_DIR}/harbor.key|g" \
  -e "s|__HARBOR_DATA_DIR__|${DATA_DIR}|g" \
  "$HARBOR_TEMPLATE" \
  > "$HARBOR_CONFIG"

grep -q "job_loggers" "$HARBOR_CONFIG" \
  || err "harbor.yml is missing jobservice.job_loggers. Update infra/harbor/harbor.yml.tmpl for Harbor ${HARBOR_VERSION}."

grep -q "webhook_job_http_client_timeout" "$HARBOR_CONFIG" \
  || err "harbor.yml is missing notification.webhook_job_http_client_timeout. Update infra/harbor/harbor.yml.tmpl for Harbor ${HARBOR_VERSION}."

log "Generated config:"
log "  ${HARBOR_CONFIG}"

# ---------------------------------------------------------------------------
# Docker visibility preflight
# ---------------------------------------------------------------------------

log "Checking Docker can see Harbor certs via patched /hostfs mount..."

docker run --rm \
  -v "${REPO_ROOT}:/hostfs${REPO_ROOT}" \
  alpine:3.20 \
  test -f "/hostfs${INSTALL_CERTS_DIR}/harbor.key" \
  || err "Docker cannot see ${INSTALL_CERTS_DIR}/harbor.key via patched /hostfs mount."

# ---------------------------------------------------------------------------
# Start Harbor
# ---------------------------------------------------------------------------

log "Running Harbor prepare..."
cd "$HARBOR_INSTALL_DIR"

# goharbor/prepare only publishes linux/amd64 images; force that platform so
# the prepare step works on arm64 hosts, including Apple Silicon.
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
log "The local demo CA is here:"
log "  ${CA_CRT}"
log ""
log "Next steps:"
log "  1) Add the /etc/hosts entry above if needed"
log "  2) Open Harbor and create project: proverjay"
log "  3) Create the k3d cluster: make harbor-cluster-create"
