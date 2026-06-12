.PHONY: test run tidy

IMAGE_NAME ?= proverjay
IMAGE_TAG ?= local

docker-build:
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

docker-run:
	docker run --rm -p 8088:8080 $(IMAGE_NAME):$(IMAGE_TAG)

test:
	go test ./...

run:
	go run ./cmd/server

tidy:
	go mod tidy
