.PHONY: test run tidy

test:
	go test ./...

run:
	go run ./cmd/server

tidy:
	go mod tidy
