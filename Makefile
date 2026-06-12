.PHONY: \
	test run tidy \
	docker-build docker-run \
	cluster-create cluster-delete cluster-check \
	install-kyverno kyverno-status kyverno-apply-policies kyverno-policy-status \
	k8s-deploy k8s-status k8s-delete k8s-test \
	verify-image verify-provenance verify-release \
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

kyverno-policy-status:
	kubectl get clusterpolicy
	kubectl get policyreports -A


# -----------------------------------------------------------------------------
# Supply chain verification
# -----------------------------------------------------------------------------

IMAGE_DIGEST ?= ghcr.io/h3ow3d/proverjay@sha256:99f085932b94b971ed28953cad33e74d2ccea1d11eaa6a59daf7ad7a8ceb425e

COSIGN_ISSUER ?= https://token.actions.githubusercontent.com
COSIGN_IDENTITY_REGEXP ?= https://github.com/h3ow3d/proverjay/.github/workflows/.*

SLSA_BUILDER_ID ?= https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml
SLSA_SOURCE_URI ?= github.com/h3ow3d/proverjay

verify-image:
	cosign verify \
		--certificate-identity-regexp="$(COSIGN_IDENTITY_REGEXP)" \
		--certificate-oidc-issuer="$(COSIGN_ISSUER)" \
		$(IMAGE_DIGEST)

verify-provenance:
	slsa-verifier verify-image \
		$(IMAGE_DIGEST) \
		--source-uri $(SLSA_SOURCE_URI) \
		--builder-id $(SLSA_BUILDER_ID)

verify-release: verify-image verify-provenance


# -----------------------------------------------------------------------------
# Full local environment
# -----------------------------------------------------------------------------

bootstrap: cluster-create install-kyverno kyverno-status k8s-deploy k8s-status k8s-test

reset-cluster: cluster-delete bootstrap
