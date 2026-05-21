FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o jwt-mock .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app/jwt-mock /jwt-mock
EXPOSE 8080
ENTRYPOINT ["/jwt-mock"]
