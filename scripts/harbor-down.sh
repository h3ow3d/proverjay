#!/usr/bin/env bash
set -euo pipefail

# harbor-down.sh — stop the local Harbor Docker Compose stack.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARBOR_INSTALL_DIR="${REPO_ROOT}/infra/harbor/installer/harbor"

log() { echo "[harbor-down] $*"; }

if [[ ! -f "${HARBOR_INSTALL_DIR}/docker-compose.yml" ]]; then
  log "Harbor Docker Compose file not found at ${HARBOR_INSTALL_DIR}/docker-compose.yml"
  log "Nothing to stop."
  exit 0
fi

cd "$HARBOR_INSTALL_DIR"
docker compose down
log "Harbor stopped."
