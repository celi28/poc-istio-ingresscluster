FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o ext-authz .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app/ext-authz /ext-authz
EXPOSE 9000
ENTRYPOINT ["/ext-authz"]
