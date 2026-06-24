#!/usr/bin/env bash
set -euo pipefail

# harbor-cluster-create.sh — detect the Docker host IP reachable from k3d
# container nodes, patch infra/k3d/cluster-harbor-local.yaml.tmpl with that
# IP, and create the k3d cluster.
#
# Env vars (all optional):
#   HARBOR_HOST_IP  — override auto-detected Docker host IP

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${REPO_ROOT}/infra/k3d/cluster-harbor-local.yaml.tmpl"
GENERATED="${REPO_ROOT}/infra/k3d/cluster-harbor-local.yaml"

log() { echo "[harbor-cluster-create] $*"; }
err() { echo "[harbor-cluster-create] ERROR: $*" >&2; exit 1; }

command -v k3d    >/dev/null 2>&1 || err "k3d is required"
command -v docker >/dev/null 2>&1 || err "docker is required"

# ---------------------------------------------------------------------------
# Detect Docker host IP
# ---------------------------------------------------------------------------

if [[ -n "${HARBOR_HOST_IP:-}" ]]; then
  log "Using HARBOR_HOST_IP from environment: ${HARBOR_HOST_IP}"
else
  # On Linux the Docker bridge gateway is reachable from inside containers.
  HARBOR_HOST_IP=$(docker network inspect bridge \
    --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)

  # Fallback for Docker Desktop (macOS / Windows).
  if [[ -z "$HARBOR_HOST_IP" ]]; then
    HARBOR_HOST_IP=$(docker run --rm --add-host host.docker.internal:host-gateway \
      alpine sh -c "getent hosts host.docker.internal | cut -f1 -d' '" 2>/dev/null || true)
  fi

  [[ -n "$HARBOR_HOST_IP" ]] || \
    err "Could not auto-detect Docker host IP. Set HARBOR_HOST_IP manually and re-run."

  log "Detected Docker host IP: ${HARBOR_HOST_IP}"
fi

# ---------------------------------------------------------------------------
# Generate cluster config
# ---------------------------------------------------------------------------

sed "s/__HARBOR_HOST_IP__/${HARBOR_HOST_IP}/g" "$TEMPLATE" > "$GENERATED"
log "Generated cluster config: infra/k3d/cluster-harbor-local.yaml"

# ---------------------------------------------------------------------------
# Create cluster
# ---------------------------------------------------------------------------

k3d cluster create --config "$GENERATED"
