#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="kyverno"
DEPLOYMENT="kyverno-admission-controller"
SECRET_NAME="harbor-pull-secret"

log() { echo "[patch-kyverno-local-harbor] $*"; }
err() { echo "[patch-kyverno-local-harbor] ERROR: $*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || err "kubectl is required"
command -v python3 >/dev/null 2>&1 || err "python3 is required"

log "Ensuring Harbor registry secret exists in kyverno namespace..."

kubectl create secret docker-registry "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --docker-server=harbor.proverjay.test \
  --docker-username=admin \
  --docker-password='Harbor12345' \
  --dry-run=client \
  -o yaml | kubectl apply -f -

log "Patching ${DEPLOYMENT} with local Harbor verification settings..."

python3 <<'PY'
import json
import subprocess
import sys

namespace = "kyverno"
deployment = "kyverno-admission-controller"
secret_name = "harbor-pull-secret"

raw = subprocess.check_output([
    "kubectl", "-n", namespace, "get", "deployment", deployment, "-o", "json"
], text=True)

obj = json.loads(raw)
containers = obj["spec"]["template"]["spec"]["containers"]

if not containers:
    print("No containers found on deployment", file=sys.stderr)
    sys.exit(1)

# The admission controller deployment normally has one container.
container = containers[0]
container_name = container["name"]
args = list(container.get("args", []))

def upsert_arg(prefix: str, value: str) -> None:
    global args
    args = [
        arg for arg in args
        if not (arg == prefix or arg.startswith(prefix + "="))
    ]
    args.append(value)

upsert_arg("--allowInsecureRegistry", "--allowInsecureRegistry=true")
upsert_arg("--imagePullSecrets", f"--imagePullSecrets={secret_name}")

patch = {
    "spec": {
        "template": {
            "spec": {
                "containers": [
                    {
                        "name": container_name,
                        "args": args,
                    }
                ]
            }
        }
    }
}

subprocess.check_call([
    "kubectl", "-n", namespace, "patch", "deployment", deployment,
    "--type", "strategic",
    "-p", json.dumps(patch),
])

print("Patched container:", container_name)
print("Args:")
for arg in args:
    print(" ", arg)
PY

log "Waiting for Kyverno admission controller rollout..."

if ! kubectl rollout status deployment/"${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=180s; then
  log "Rollout failed. Recent logs:"
  kubectl logs deployment/"${DEPLOYMENT}" -n "${NAMESPACE}" --tail=100 || true
  exit 1
fi

log "Kyverno admission controller is ready."

log "Current admission controller args:"
kubectl -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" \
  -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{.}{"\n"}{end}'
