FROM golang:1.26-alpine AS build

WORKDIR /src

COPY go.mod ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -o /bin/proverjay ./cmd/server


FROM alpine:3.22

RUN adduser -D -H appuser

USER appuser

COPY --from=build /bin/proverjay /bin/proverjay

EXPOSE 8080

ENTRYPOINT ["/bin/proverjay"]
