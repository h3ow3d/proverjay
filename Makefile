.PHONY: test run tidy

IMAGE_NAME ?= proverjay
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

test:
	go test ./...

run:
	go run ./cmd/server

tidy:
	go mod tidy
