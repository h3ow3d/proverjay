#!/usr/bin/env bash
set -euo pipefail

HARBOR_HOSTNAME="${HARBOR_HOSTNAME:-harbor.proverjay.test}"
HARBOR_USERNAME="${HARBOR_USERNAME:-admin}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-Harbor12345}"
APP_NAMESPACE="${APP_NAMESPACE:-proverjay}"
KYVERNO_NAMESPACE="${KYVERNO_NAMESPACE:-kyverno}"
SECRET_NAME="${SECRET_NAME:-harbor-pull-secret}"

log() { echo "[create-harbor-k8s-secrets] $*"; }

log "Creating Harbor pull secret in app namespace: ${APP_NAMESPACE}"

kubectl create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry "${SECRET_NAME}" \
  --namespace "${APP_NAMESPACE}" \
  --docker-server="${HARBOR_HOSTNAME}" \
  --docker-username="${HARBOR_USERNAME}" \
  --docker-password="${HARBOR_PASSWORD}" \
  --dry-run=client \
  -o yaml | kubectl apply -f -

log "Patching default service account in ${APP_NAMESPACE}"

kubectl patch serviceaccount default \
  --namespace "${APP_NAMESPACE}" \
  --type='merge' \
  -p "{\"imagePullSecrets\":[{\"name\":\"${SECRET_NAME}\"}]}" \
  >/dev/null

if kubectl get namespace "${KYVERNO_NAMESPACE}" >/dev/null 2>&1; then
  log "Creating Harbor pull secret in Kyverno namespace: ${KYVERNO_NAMESPACE}"

  kubectl create secret docker-registry "${SECRET_NAME}" \
    --namespace "${KYVERNO_NAMESPACE}" \
    --docker-server="${HARBOR_HOSTNAME}" \
    --docker-username="${HARBOR_USERNAME}" \
    --docker-password="${HARBOR_PASSWORD}" \
    --dry-run=client \
    -o yaml | kubectl apply -f -
else
  log "Kyverno namespace does not exist yet; skipping Kyverno registry secret for now."
  log "Run this script again after installing Kyverno."
fi

log "Done."
