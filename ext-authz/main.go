package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	core "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	auth "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	envoy_type "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"github.com/getkin/kin-openapi/openapi3"
	rpcstatus "google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
)

type cachedSpec struct {
	doc       *openapi3.T
	fetchedAt time.Time
}

type authzServer struct {
	auth.UnimplementedAuthorizationServer

	apicurioURL   string
	artifactGroup string
	artifactID    string
	maxBodyBytes  int64
	cacheTTL      time.Duration

	mu    sync.RWMutex
	cache map[string]cachedSpec
}

func main() {
	listenAddr := envOrDefault("LISTEN_ADDR", ":9000")
	apicurioURL := envOrDefault("APICURIO_URL", "http://apicurio-registry.apicurio.svc.cluster.local:8080")
	artifactGroup := envOrDefault("ARTIFACT_GROUP", "demo")
	artifactID := envOrDefault("ARTIFACT_ID", "demo-api")
	cacheTTL := mustParseDuration(envOrDefault("CACHE_TTL", "60s"))
	maxBodyBytes := mustParseInt64(envOrDefault("MAX_BODY_BYTES", "1048576"))

	srv := &authzServer{
		apicurioURL:   apicurioURL,
		artifactGroup: artifactGroup,
		artifactID:    artifactID,
		maxBodyBytes:  maxBodyBytes,
		cacheTTL:      cacheTTL,
		cache:         make(map[string]cachedSpec),
	}

	lis, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	grpcServer := grpc.NewServer()
	auth.RegisterAuthorizationServer(grpcServer, srv)
	grpc_health_v1.RegisterHealthServer(grpcServer, srv)
	reflection.Register(grpcServer)

	log.Printf("ext-authz listening on %s (apicurio: %s, group: %s, artifact: %s)",
		listenAddr, apicurioURL, artifactGroup, artifactID)

	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("gRPC server error: %v", err)
	}
}

// Check implements envoy.service.auth.v3.Authorization
func (s *authzServer) Check(ctx context.Context, req *auth.CheckRequest) (*auth.CheckResponse, error) {
	httpReq := req.GetAttributes().GetRequest().GetHttp()

	method := strings.ToUpper(httpReq.GetMethod())
	path := httpReq.GetPath()
	body := httpReq.GetBody()
	headers := httpReq.GetHeaders()

	// Strip query string from path for matching
	pathOnly := path
	if idx := strings.Index(path, "?"); idx != -1 {
		pathOnly = path[:idx]
	}

	// 1. Body size check
	if int64(len(body)) > s.maxBodyBytes {
		return denyHTTP(http.StatusRequestEntityTooLarge, "request body too large"), nil
	}

	// 2. Fetch spec (with cache)
	spec, err := s.getSpec(ctx)
	if err != nil {
		log.Printf("ERROR fetching spec from Apicurio: %v — denying request", err)
		return denyHTTP(http.StatusServiceUnavailable, "schema service unavailable"), nil
	}

	// 3. Match path + method to an OpenAPI operation
	op, err := matchOperation(spec, method, pathOnly)
	if err != nil {
		return denyHTTP(http.StatusNotFound, fmt.Sprintf("no route for %s %s", method, pathOnly)), nil
	}

	// 4. Validate Content-Type for body-carrying methods
	if method == http.MethodPost || method == http.MethodPut || method == http.MethodPatch {
		ct := headers["content-type"]
		if !strings.HasPrefix(strings.ToLower(ct), "application/json") {
			return denyHTTP(http.StatusUnsupportedMediaType, "content-type must be application/json"), nil
		}
	}

	// 5. Validate JSON body against OpenAPI request body schema
	if op.RequestBody != nil && op.RequestBody.Value != nil && op.RequestBody.Value.Required {
		if err := validateJSONBody(op, body); err != nil {
			return denyHTTP(http.StatusBadRequest, err.Error()), nil
		}
	}

	return &auth.CheckResponse{
		Status: &rpcstatus.Status{Code: int32(codes.OK)},
		HttpResponse: &auth.CheckResponse_OkResponse{
			OkResponse: &auth.OkHttpResponse{},
		},
	}, nil
}

// getSpec returns the cached spec or fetches it from Apicurio.
func (s *authzServer) getSpec(ctx context.Context) (*openapi3.T, error) {
	key := fmt.Sprintf("%s:%s", s.artifactGroup, s.artifactID)

	s.mu.RLock()
	cached, ok := s.cache[key]
	s.mu.RUnlock()

	if ok && time.Since(cached.fetchedAt) < s.cacheTTL {
		return cached.doc, nil
	}

	url := fmt.Sprintf("%s/apis/registry/v2/groups/%s/artifacts/%s",
		s.apicurioURL, s.artifactGroup, s.artifactID)

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Accept", "application/json")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("Apicurio returned %d for %s", resp.StatusCode, url)
	}

	rawSpec, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("reading spec body: %w", err)
	}

	loader := openapi3.NewLoader()
	doc, err := loader.LoadFromData(rawSpec)
	if err != nil {
		return nil, fmt.Errorf("parsing OpenAPI spec: %w", err)
	}

	if err := doc.Validate(ctx); err != nil {
		return nil, fmt.Errorf("invalid OpenAPI spec: %w", err)
	}

	s.mu.Lock()
	s.cache[key] = cachedSpec{doc: doc, fetchedAt: time.Now()}
	s.mu.Unlock()

	log.Printf("Loaded spec %s from Apicurio (%d paths)", key, len(doc.Paths.Map()))
	return doc, nil
}

// matchOperation finds the OpenAPI operation matching method and path.
func matchOperation(doc *openapi3.T, method, path string) (*openapi3.Operation, error) {
	for pattern, item := range doc.Paths.Map() {
		if !pathMatches(pattern, path) {
			continue
		}
		var op *openapi3.Operation
		switch method {
		case http.MethodGet:
			op = item.Get
		case http.MethodPost:
			op = item.Post
		case http.MethodPut:
			op = item.Put
		case http.MethodPatch:
			op = item.Patch
		case http.MethodDelete:
			op = item.Delete
		case http.MethodHead:
			op = item.Head
		case http.MethodOptions:
			op = item.Options
		}
		if op != nil {
			return op, nil
		}
	}
	return nil, fmt.Errorf("no operation matched")
}

// pathMatches checks whether a concrete path matches an OpenAPI path template.
// e.g. "/items/42" matches "/items/{id}".
func pathMatches(template, path string) bool {
	tParts := strings.Split(strings.Trim(template, "/"), "/")
	pParts := strings.Split(strings.Trim(path, "/"), "/")
	if len(tParts) != len(pParts) {
		return false
	}
	for i, t := range tParts {
		if strings.HasPrefix(t, "{") && strings.HasSuffix(t, "}") {
			continue
		}
		if t != pParts[i] {
			return false
		}
	}
	return true
}

// validateJSONBody validates the request body against the operation's JSON schema.
func validateJSONBody(op *openapi3.Operation, body string) error {
	if body == "" {
		return fmt.Errorf("request body is required but empty")
	}

	jsonContent, ok := op.RequestBody.Value.Content["application/json"]
	if !ok || jsonContent.Schema == nil {
		return nil
	}

	schema := jsonContent.Schema.Value
	if schema == nil {
		return nil
	}

	var parsed interface{}
	if err := json.Unmarshal([]byte(body), &parsed); err != nil {
		return fmt.Errorf("invalid JSON: %v", err)
	}

	if err := schema.VisitJSON(parsed); err != nil {
		return fmt.Errorf("schema validation failed: %v", err)
	}

	return nil
}

// denyHTTP builds a CheckResponse that translates to the given HTTP status code.
func denyHTTP(httpStatus int, msg string) *auth.CheckResponse {
	var grpcCode codes.Code
	switch httpStatus {
	case http.StatusBadRequest:
		grpcCode = codes.InvalidArgument
	case http.StatusNotFound:
		grpcCode = codes.NotFound
	case http.StatusForbidden:
		grpcCode = codes.PermissionDenied
	case http.StatusRequestEntityTooLarge:
		grpcCode = codes.ResourceExhausted
	default:
		grpcCode = codes.Internal
	}

	return &auth.CheckResponse{
		Status: &rpcstatus.Status{
			Code:    int32(grpcCode),
			Message: msg,
		},
		HttpResponse: &auth.CheckResponse_DeniedResponse{
			DeniedResponse: &auth.DeniedHttpResponse{
				Status: &envoy_type.HttpStatus{
					Code: envoy_type.StatusCode(httpStatus),
				},
				Headers: []*core.HeaderValueOption{
					{
						Header: &core.HeaderValue{
							Key:   "content-type",
							Value: "application/json",
						},
					},
				},
				Body: fmt.Sprintf(`{"error":"%s"}`, msg),
			},
		},
	}
}

// Check implements grpc_health_v1.HealthServer
func (s *authzServer) Check(_ context.Context, _ *grpc_health_v1.HealthCheckRequest) (*grpc_health_v1.HealthCheckResponse, error) {
	return &grpc_health_v1.HealthCheckResponse{
		Status: grpc_health_v1.HealthCheckResponse_SERVING,
	}, nil
}

// Watch implements grpc_health_v1.HealthServer (streaming, not used)
func (s *authzServer) Watch(_ *grpc_health_v1.HealthCheckRequest, stream grpc_health_v1.Health_WatchServer) error {
	return stream.Send(&grpc_health_v1.HealthCheckResponse{
		Status: grpc_health_v1.HealthCheckResponse_SERVING,
	})
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func mustParseDuration(s string) time.Duration {
	d, err := time.ParseDuration(s)
	if err != nil {
		log.Fatalf("invalid duration %q: %v", s, err)
	}
	return d
}

func mustParseInt64(s string) int64 {
	var n int64
	if _, err := fmt.Sscanf(s, "%d", &n); err != nil {
		log.Fatalf("invalid int64 %q: %v", s, err)
	}
	return n
}
