FROM golang:1.26-alpine AS build

WORKDIR /src

COPY go.mod ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -o /bin/proverjay ./cmd/server


FROM alpine:3.22

ARG VERSION=dev
ARG COMMIT=unknown
ARG CREATED=unknown

LABEL org.opencontainers.image.title="proverjay"
LABEL org.opencontainers.image.description="A small Go app for hardened supply chain demos"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.revision="${COMMIT}"
LABEL org.opencontainers.image.created="${CREATED}"
LABEL org.opencontainers.image.source="https://github.com/<your-github-user>/proverjay"

RUN adduser -D -H appuser

USER appuser

COPY --from=build /bin/proverjay /bin/proverjay

EXPOSE 8080

ENTRYPOINT ["/bin/proverjay"]
