.PHONY: test run tidy

IMAGE_NAME ?= proverjay
IMAGE_TAG ?= local
VERSION ?= dev
COMMIT ?= $(shell git rev-parse --short HEAD)
CREATED ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
K3D_CLUSTER ?= proverjay
K3D_CONFIG ?= infra/k3d/cluster.yaml
K8S_NAMESPACE ?= proverjay
K8S_DIR ?= deploy/k8s
COSIGN_ISSUER ?= https://token.actions.githubusercontent.com
COSIGN_IDENTITY_REGEXP ?= https://github.com/h3ow3d/proverjay/.github/workflows/.*
IMAGE_DIGEST ?= ghcr.io/h3ow3d/proverjay@sha256:7d9e9868c4d4d7ee1bed07e11ce187d584e99d522bbf73ba133a0077f73f5b9a
SLSA_BUILDER_ID ?= https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml
SLSA_SOURCE_URI ?= github.com/h3ow3d/proverjay

verify-provenance:
	slsa-verifier verify-image \
		$(IMAGE_DIGEST) \
		--source-uri $(SLSA_SOURCE_URI) \
		--builder-id $(SLSA_BUILDER_ID)


verify-image:
	cosign verify \
		--certificate-identity-regexp="$(COSIGN_IDENTITY_REGEXP)" \
		--certificate-oidc-issuer="$(COSIGN_ISSUER)" \
		$(IMAGE_DIGEST)

k8s-deploy:
	kubectl apply -f $(K8S_DIR)

k8s-status:
	kubectl get all -n $(K8S_NAMESPACE)

k8s-delete:
	kubectl delete -f $(K8S_DIR)

k8s-test:
	curl localhost:8087/health


cluster-create:
	k3d cluster create --config $(K3D_CONFIG)

cluster-delete:
	k3d cluster delete $(K3D_CLUSTER)

cluster-check:
	kubectl cluster-info
	kubectl get nodes


docker-build:
	docker build \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		--build-arg CREATED=$(CREATED) \
		-t $(IMAGE_NAME):$(IMAGE_TAG) .

docker-run:
	docker run --rm -p 8088:8080 $(IMAGE_NAME):$(IMAGE_TAG)

test:
	go test ./...

run:
	go run ./cmd/server

tidy:
	go mod tidy
