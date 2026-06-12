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
