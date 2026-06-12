.PHONY: test run tidy

IMAGE_NAME ?= proverjay
IMAGE_TAG ?= local
VERSION ?= dev
COMMIT ?= $(shell git rev-parse --short HEAD)
CREATED ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
K3D_CLUSTER ?= proverjay
K3D_CONFIG ?= infra/k3d/cluster.yaml

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
