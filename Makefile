.PHONY: \
	test run tidy \
	docker-build docker-run \
	cluster-create cluster-delete cluster-check \
	install-kyverno kyverno-status kyverno-apply-policies kyverno-apply-harbor-policies kyverno-policy-status \
	k8s-deploy k8s-deploy-harbor k8s-status k8s-delete k8s-test \
	verify-image verify-provenance verify-release \
	offline-export offline-import-harbor promote-release-harbor deploy-harbor-release harbor-demo harbor-demo-status offline-demo-sanity \
	harbor-certs harbor-cert-status harbor-setup harbor-health harbor-down harbor-cluster-create \
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
# Docker local build/dev
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
	kubectl get clusterpolicy || true
	kubectl get imagevalidatingpolicy || true
	kubectl describe clusterpolicy require-private-harbor-source || true
	kubectl describe imagevalidatingpolicy require-signed-proverjay-harbor-image || true


# -----------------------------------------------------------------------------
# Supply chain verification
# -----------------------------------------------------------------------------

RELEASE_PACKAGE ?= proverjay
RELEASE_TAG ?= af304bfc4159dd945dff0c086a56555f60c556a3
RELEASE_IMAGE ?= ghcr.io/h3ow3d/$(RELEASE_PACKAGE):$(RELEASE_TAG)

BUNDLE_DIR ?= dist
BUNDLE ?= $(BUNDLE_DIR)/$(RELEASE_PACKAGE)-$(RELEASE_TAG).oci-bundle.tar.gz

HARBOR_HOSTNAME ?= harbor.proverjay.test
HARBOR_PROJECT ?= proverjay
HARBOR_IMAGE ?= $(RELEASE_PACKAGE)
HARBOR_TAG ?= $(RELEASE_TAG)
HARBOR_RELEASE_IMAGE ?= $(HARBOR_HOSTNAME)/$(HARBOR_PROJECT)/$(HARBOR_IMAGE):$(HARBOR_TAG)

# Current GHCR image is keyless/certificate-signed by GitHub Actions.
# Exact SAN observed from cosign:
# https://github.com/h3ow3d/proverjay/.github/workflows/ci.yaml@refs/tags/v0.1.11
COSIGN_CERT_OIDC_ISSUER ?= https://token.actions.githubusercontent.com
COSIGN_CERT_IDENTITY ?= https://github.com/h3ow3d/proverjay/.github/workflows/ci.yaml@refs/tags/v0.1.11

# Set to true once the release workflow publishes a real SLSA provenance
# attestation for the runtime image.
REQUIRE_PROVENANCE ?= false

verify-image:
	cosign verify \
		--certificate-oidc-issuer "$(COSIGN_CERT_OIDC_ISSUER)" \
		--certificate-identity "$(COSIGN_CERT_IDENTITY)" \
		"$(RELEASE_IMAGE)"

verify-provenance:
	cosign verify-attestation \
		--type slsaprovenance \
		--certificate-oidc-issuer "$(COSIGN_CERT_OIDC_ISSUER)" \
		--certificate-identity "$(COSIGN_CERT_IDENTITY)" \
		"$(RELEASE_IMAGE)"

verify-release: verify-image
	@if [ "$(REQUIRE_PROVENANCE)" = "true" ]; then \
		$(MAKE) verify-provenance; \
	else \
		echo ""; \
		echo "Skipping SLSA provenance verification because REQUIRE_PROVENANCE=false."; \
		echo "Image signature verification passed for:"; \
		echo "  $(RELEASE_IMAGE)"; \
	fi


# -----------------------------------------------------------------------------
# GHCR -> Harbor promotion
# -----------------------------------------------------------------------------

offline-export:
	RELEASE_IMAGE="$(RELEASE_IMAGE)" \
	BUNDLE_DIR="$(BUNDLE_DIR)" \
	./scripts/offline-export.sh

offline-import-harbor:
	BUNDLE="$(BUNDLE)" \
	HARBOR_HOSTNAME="$(HARBOR_HOSTNAME)" \
	HARBOR_PROJECT="$(HARBOR_PROJECT)" \
	IMAGE_NAME="$(HARBOR_IMAGE)" \
	IMAGE_TAG="$(HARBOR_TAG)" \
	./scripts/offline-import-harbor.sh

promote-release-harbor: verify-release offline-export offline-import-harbor
	@echo ""
	@echo "Promoted verified release into Harbor:"
	@echo "  $(RELEASE_IMAGE)"
	@echo "  -> $(HARBOR_RELEASE_IMAGE)"

deploy-harbor-release: k8s-deploy-harbor k8s-status k8s-test

harbor-demo: harbor-health cluster-check install-kyverno kyverno-apply-harbor-policies promote-release-harbor deploy-harbor-release harbor-demo-status
	@echo ""
	@echo "Harbor demo complete:"
	@echo "  verified GHCR release signature"
	@echo "  promoted to Harbor"
	@echo "  deployed from Harbor into k3d"
	@echo "  Kyverno Harbor policies applied"

harbor-demo-status:
	kubectl get clusterpolicy require-private-harbor-source || true
	kubectl get imagevalidatingpolicy require-signed-proverjay-harbor-image || true
	kubectl get all -n $(K8S_NAMESPACE) || true

offline-demo-sanity:
	test -x scripts/offline-export.sh
	test -x scripts/offline-import-harbor.sh
	test -x scripts/harbor-setup.sh
	test -x scripts/harbor-cluster-create.sh
	bash -n scripts/offline-export.sh scripts/offline-import-harbor.sh scripts/harbor-setup.sh scripts/harbor-cluster-create.sh
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
# Harbor local Docker Compose
# -----------------------------------------------------------------------------

HARBOR_VERSION ?= v2.11.2
HARBOR_DIR ?= infra/harbor
HARBOR_CERT_DIR ?= $(HARBOR_DIR)/certs
HARBOR_CERT ?= $(HARBOR_CERT_DIR)/harbor.crt
HARBOR_KEY ?= $(HARBOR_CERT_DIR)/harbor.key
HARBOR_CA ?= $(HARBOR_DIR)/harbor-ca.crt

harbor-certs:
	mkdir -p $(HARBOR_CERT_DIR)
	test -f $(HARBOR_CERT) -a -f $(HARBOR_KEY) || \
	openssl req -x509 -nodes -newkey rsa:4096 \
		-keyout $(HARBOR_KEY) \
		-out $(HARBOR_CERT) \
		-days 365 \
		-subj "/CN=$(HARBOR_HOSTNAME)" \
		-addext "subjectAltName=DNS:$(HARBOR_HOSTNAME)"

harbor-cert-status:
	ls -l $(HARBOR_CERT_DIR) || true
	test -f $(HARBOR_CERT) && openssl x509 -in $(HARBOR_CERT) -noout -subject -issuer -dates || true
	test -f $(HARBOR_CA) && openssl x509 -in $(HARBOR_CA) -noout -subject -issuer -dates || true

harbor-setup: harbor-certs
	HARBOR_VERSION="$(HARBOR_VERSION)" \
	HARBOR_HOSTNAME="$(HARBOR_HOSTNAME)" \
	./scripts/harbor-setup.sh

harbor-health:
	curl -kfsS https://$\(HARBOR_HOSTNAME\)/api/v2.0/health

harbor-down:
	./scripts/harbor-down.sh

harbor-cluster-create:
	./scripts/harbor-cluster-create.sh
