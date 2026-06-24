#!/usr/bin/env bash
set -euo pipefail

K3D_CLUSTER="${K3D_CLUSTER:-proverjay}"
HARBOR_HOSTNAME="${HARBOR_HOSTNAME:-harbor.proverjay.test}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${REPO_ROOT}/infra/k3d/cluster-harbor-local.yaml.tmpl"
GENERATED="${REPO_ROOT}/infra/k3d/cluster-harbor-local.yaml"

HARBOR_CA_SOURCE="../harbor/harbor-ca.crt"
HARBOR_CA_ABS="${REPO_ROOT}/infra/harbor/harbor-ca.crt"

log() { echo "[harbor-cluster-create] $*"; }
err() { echo "[harbor-cluster-create] ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "$1 is required"
}

require_cmd k3d
require_cmd docker
require_cmd curl
require_cmd sed
require_cmd grep

[[ -f "$TEMPLATE" ]] || err "Missing template: $TEMPLATE"
[[ -f "$HARBOR_CA_ABS" ]] || err "Missing Harbor CA cert: $HARBOR_CA_ABS. Run make harbor-setup first."

if ! printf '%s' "$K3D_CLUSTER" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'; then
  err "K3D_CLUSTER must be DNS/hostname-like. Got: $K3D_CLUSTER"
fi

log "Checking Harbor is healthy from the host..."

curl -kfsS \
  --connect-timeout 5 \
  --max-time 10 \
  "https://${HARBOR_HOSTNAME}/api/v2.0/health" \
  | grep -q '"status":"healthy"' \
  || err "Harbor is not healthy from the host at https://${HARBOR_HOSTNAME}"

log "Resolving Docker host-gateway to a real IPv4 address..."

HARBOR_HOST_IP="$(
  docker run --rm \
    --add-host gateway-probe:host-gateway \
    alpine:3.20 \
    sh -c "awk '\$2 == \"gateway-probe\" && \$1 ~ /^[0-9]+\\./ {print \$1; exit}' /etc/hosts" \
    2>/dev/null || true
)"

if [[ -z "$HARBOR_HOST_IP" ]]; then
  err "Could not resolve Docker host-gateway to an IPv4 address."
fi

if printf '%s' "$HARBOR_HOST_IP" | grep -q ':'; then
  err "Resolved host-gateway to IPv6, which k3d hostAliases cannot use here: $HARBOR_HOST_IP"
fi

log "Docker host-gateway IPv4: ${HARBOR_HOST_IP}"

log "Checking Harbor is reachable from a Docker container..."

docker run --rm \
  --add-host "${HARBOR_HOSTNAME}:${HARBOR_HOST_IP}" \
  curlimages/curl:8.10.1 \
  -kfsS \
  --connect-timeout 5 \
  --max-time 10 \
  "https://${HARBOR_HOSTNAME}/api/v2.0/health" \
  | grep -q '"status":"healthy"' \
  || err "Harbor was not reachable from Docker using ${HARBOR_HOST_IP}"

log "Generating k3d cluster config..."

sed \
  -e "s|__K3D_CLUSTER__|${K3D_CLUSTER}|g" \
  -e "s|__HARBOR_HOSTNAME__|${HARBOR_HOSTNAME}|g" \
  -e "s|__HARBOR_HOST_IP__|${HARBOR_HOST_IP}|g" \
  -e "s|__HARBOR_CA_SOURCE__|${HARBOR_CA_SOURCE}|g" \
  "$TEMPLATE" > "$GENERATED"

if grep -q "__.*__" "$GENERATED"; then
  log "Generated config still contains unresolved placeholders:"
  grep -n "__.*__" "$GENERATED" || true
  err "Refusing to create k3d cluster with unresolved placeholders."
fi

log "Generated cluster config: infra/k3d/cluster-harbor-local.yaml"

k3d cluster create --config "$GENERATED"

log "Cluster created: ${K3D_CLUSTER}"
log ""
log "Next checks:"
log "  kubectl get nodes"
log "  kubectl get pods -A"
