.PHONY: \
	test run tidy \
	docker-build docker-run \
	cluster-create cluster-delete cluster-check \
	install-kyverno kyverno-status kyverno-apply-policies kyverno-apply-harbor-policies kyverno-policy-status \
	k8s-deploy k8s-deploy-harbor k8s-status k8s-delete k8s-test \
	verify-image verify-provenance verify-release \
	offline-export offline-import-harbor harbor-demo-status offline-demo-sanity \
	harbor-setup harbor-down harbor-cluster-create \
	bootstrap reset-cluster

# -----------------------------------------------------------------------------
# App
# -----------------------------------------------------------------------------

APP_NAME ?= proverjay

test:
	go test ./...

run:
	go run ./cmd/server

tidy:
	go mod tidy


# -----------------------------------------------------------------------------
# Docker
# -----------------------------------------------------------------------------

IMAGE_NAME ?= $(APP_NAME)
IMAGE_TAG ?= local
VERSION ?= dev
COMMIT ?= $(shell git rev-parse --short HEAD)
CREATED ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

docker-build:
	docker build \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		--build-arg CREATED=$(CREATED) \
		-t $(IMAGE_NAME):$(IMAGE_TAG) .

docker-run:
	docker run --rm -p 8088:8080 $(IMAGE_NAME):$(IMAGE_TAG)


# -----------------------------------------------------------------------------
# k3d
# -----------------------------------------------------------------------------

K3D_CLUSTER ?= proverjay
K3D_CONFIG ?= infra/k3d/cluster.yaml

cluster-create:
	k3d cluster create --config $(K3D_CONFIG)

cluster-delete:
	k3d cluster delete $(K3D_CLUSTER) || true

cluster-check:
	kubectl cluster-info
	kubectl get nodes


# -----------------------------------------------------------------------------
# Kubernetes app deployment
# -----------------------------------------------------------------------------

K8S_NAMESPACE ?= proverjay
K8S_DIR ?= deploy/k8s
K8S_LOCAL_URL ?= http://localhost:8087/health

k8s-deploy:
	kubectl apply -f $(K8S_DIR)/namespace.yaml
	kubectl wait --for=jsonpath='{.status.phase}=Active' namespace/$(K8S_NAMESPACE) --timeout=30s
	kubectl apply -f $(K8S_DIR)/service.yaml
	kubectl apply -f $(K8S_DIR)/deployment.yaml

k8s-deploy-harbor:
	kubectl apply -f $(K8S_DIR)/namespace.yaml
	kubectl wait --for=jsonpath='{.status.phase}=Active' namespace/$(K8S_NAMESPACE) --timeout=30s
	kubectl apply -f $(K8S_DIR)/service.yaml
	kubectl apply -f $(K8S_DIR)/deployment-harbor.yaml

k8s-status:
	kubectl get all -n $(K8S_NAMESPACE)

k8s-delete:
	kubectl delete -f $(K8S_DIR) || true

k8s-test:
	curl --fail $(K8S_LOCAL_URL)


# -----------------------------------------------------------------------------
# Kyverno
# -----------------------------------------------------------------------------

KYVERNO_DIR ?= deploy/kyverno

install-kyverno:
	./scripts/install-kyverno.sh

kyverno-status:
	kubectl get pods -n kyverno
	kubectl get deploy -n kyverno

kyverno-apply-policies:
	kubectl apply -f $(KYVERNO_DIR)

kyverno-apply-harbor-policies:
	kubectl apply -f $(KYVERNO_DIR)/require-private-harbor-source.yaml
	kubectl apply -f $(KYVERNO_DIR)/require-signed-proverjay-harbor-image.yaml

kyverno-policy-status:
	kubectl get imagevalidatingpolicy
	kubectl describe imagevalidatingpolicy require-signed-proverjay-image


# -----------------------------------------------------------------------------
# Supply chain verification
# -----------------------------------------------------------------------------

RELEASE_IMAGE ?= ghcr.io/h3ow3d/proverjay:v0.1.10
BUNDLE_DIR ?= dist
BUNDLE ?= $(BUNDLE_DIR)/proverjay-v0.1.10.oci-bundle.tar.gz

HARBOR_HOSTNAME ?= harbor.proverjay.test
HARBOR_PROJECT ?= proverjay
HARBOR_IMAGE ?= proverjay
HARBOR_TAG ?= v0.1.10

COSIGN_PUBLIC_KEY ?= infra/cosign/cosign.pub

verify-image:
	cosign verify \
		--key "$(COSIGN_PUBLIC_KEY)" \
		"$(RELEASE_IMAGE)"

verify-provenance:
	cosign verify-attestation \
		--type slsaprovenance \
		--key "$(COSIGN_PUBLIC_KEY)" \
		"$(RELEASE_IMAGE)"

verify-release: verify-image verify-provenance

offline-export:
	RELEASE_IMAGE="$(RELEASE_IMAGE)" BUNDLE_DIR="$(BUNDLE_DIR)" ./scripts/offline-export.sh

offline-import-harbor:
	BUNDLE="$(BUNDLE)" \
	HARBOR_HOSTNAME="$(HARBOR_HOSTNAME)" \
	HARBOR_PROJECT="$(HARBOR_PROJECT)" \
	IMAGE_NAME="$(HARBOR_IMAGE)" \
	IMAGE_TAG="$(HARBOR_TAG)" \
	./scripts/offline-import-harbor.sh

harbor-demo-status:
	kubectl get clusterpolicy require-private-harbor-source || true
	kubectl get imagevalidatingpolicy require-signed-proverjay-harbor-image || true
	kubectl get all -n $(K8S_NAMESPACE)

offline-demo-sanity:
	test -x scripts/offline-export.sh
	test -x scripts/offline-import-harbor.sh
	bash -n scripts/offline-export.sh scripts/offline-import-harbor.sh
	python3 -c "import importlib.util,sys;\
files=['infra/k3d/cluster-harbor-local.yaml.tmpl','infra/k3d/registries-harbor.yaml','deploy/kyverno/require-private-harbor-source.yaml','deploy/kyverno/require-signed-proverjay-image.yaml','deploy/kyverno/require-signed-proverjay-harbor-image.yaml','deploy/k8s/deployment-harbor.yaml'];\
spec=importlib.util.find_spec('yaml');\
print('PyYAML not installed; skipping YAML parse check') if spec is None else None;\
sys.exit(0) if spec is None else None;\
import yaml;\
[yaml.safe_load(open(f,'r',encoding='utf-8')) for f in files];\
print('YAML parse check passed for',len(files),'files')"


# -----------------------------------------------------------------------------
# Full local environment
# -----------------------------------------------------------------------------

bootstrap: cluster-create install-kyverno kyverno-status k8s-deploy k8s-status k8s-test

reset-cluster: cluster-delete bootstrap


# -----------------------------------------------------------------------------
# Harbor (local Docker Compose)
# -----------------------------------------------------------------------------

HARBOR_VERSION ?= v2.11.2

harbor-setup:
	HARBOR_VERSION="$(HARBOR_VERSION)" ./scripts/harbor-setup.sh

harbor-down:
	./scripts/harbor-down.sh

harbor-cluster-create:
	./scripts/harbor-cluster-create.sh

