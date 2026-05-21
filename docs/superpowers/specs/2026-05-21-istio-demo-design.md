# Design: Istio Multi-Cluster Demo on GCP

**Date:** 2026-05-21  
**Status:** Approved  
**Source spec:** `spec-migration-istio-fr.md`

---

## Purpose

Demonstrate the architecture described in the Istio multi-cluster migration spec:
- Two GKE clusters (ingress + workload) bootstrapped with Terraform on GCP `europe-west1`
- Istio Primary-Remote with east-west gateway for cross-cluster traffic
- Apicurio Registry as OpenAPI schema store (in-memory mode)
- Custom Go ExtAuthz gRPC service validating requests against Apicurio schemas
- Mock RS512 JWT issuer for authentication validation

Target audience: platform/architecture team (PoC) + decision-makers (showcase).

---

## Architecture

```
Internet
  │
  ▼ HTTPS :443
[GCP External NLB]  ← public IP (terraform output: ingress_lb_ip)
  │
  ▼
INGRESS CLUSTER (europe-west1-b)
  │
  [Istio IngressGateway]
  │  TLS termination (cert-manager self-signed CA)
  │
  ├── RequestAuthentication (RS512)
  │   └── JWKS from jwt-mock.jwt-mock.svc:8080
  │   └── 401 if token absent or invalid
  │
  ├── AuthorizationPolicy CUSTOM (ext-authz-schema)
  │   └── gRPC Check → ext-authz.ext-authz.svc:9000
  │   └── 400/404/413 on schema violation
  │
  [VirtualService] → demo-app.app.svc.cluster.local:80
  │
  [EastWest Gateway :15443]  ←→  mTLS AUTO_PASSTHROUGH
  │
WORKLOAD CLUSTER (europe-west1-c)
  │
  [EastWest Gateway :15443]
  │
  [demo-app] (httpbin — receives validated traffic)
  │
  [InternalGateway :80/:443/:50051]
    └── datacenter traffic, no auth (not exercised in demo)
```

Supporting services on ingress-cluster:
- **Apicurio Registry** (`apicurio` ns): OpenAPI spec store, in-memory, pre-loaded with demo spec
- **ext-authz** (`ext-authz` ns): Go gRPC service, fetches spec from Apicurio, validates body/headers/path
- **jwt-mock** (`jwt-mock` ns): Go HTTP service, generates RSA-4096 keypair on boot, issues RS512 JWTs

---

## Components

| Component | Where | Image / Chart |
|---|---|---|
| istiod (primary) | ingress-cluster | `istio/istiod` Helm chart |
| istiod (remote config) | workload-cluster | `istio/istiod` Helm chart (remote values) |
| IngressGateway | ingress-cluster | `istio/gateway` |
| EastWest Gateway | both clusters | `istio/gateway` |
| InternalGateway | workload-cluster | `istio/gateway` |
| cert-manager | both clusters | `jetstack/cert-manager` |
| Apicurio Registry | ingress-cluster | `quay.io/apicurio/apicurio-registry-mem:2.5.0.Final` |
| ext-authz | ingress-cluster | custom Go image (Artifact Registry) |
| jwt-mock | ingress-cluster | custom Go image (Artifact Registry) |
| demo-app | workload-cluster | `kennethreitz/httpbin` |

---

## Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Istio model | Primary-Remote | Single istiod, simpler for demo |
| JWT IdP | Mock in-cluster issuer | Zero external deps, RS512 support |
| Schema store | Apicurio in-memory | No Postgres required |
| ExtAuthz impl | Custom Go gRPC | Minimal, directly maps to spec |
| TLS | cert-manager self-signed CA | No DNS/ACME required |
| Observability | None | Keep demo lean |
| GCP provisioning | Terraform-only | Reproducible, single `terraform apply` |
| Region | europe-west1 | Requested |

---

## ExtAuthz Validation Logic

The Go service implements `envoy.service.auth.v3.Authorization`:

```
Check(request):
  1. Body > MAX_BODY_BYTES → RESOURCE_EXHAUSTED (413)
  2. Fetch spec from Apicurio (cached 60s)
  3. Match path + method to OpenAPI operation → NOT_FOUND (404) if no match
  4. Content-Type ≠ application/json (for POST/PUT/PATCH) → INVALID_ARGUMENT (415→400)
  5. JSON body fails schema → INVALID_ARGUMENT (400)
  6. All checks pass → OK
```

Apicurio artifact: group=`demo`, id=`demo-api`, fetched via `GET /apis/registry/v2/groups/demo/artifacts/demo-api`.

---

## Demo Scenarios

| # | Scenario | Expected HTTP |
|---|---|---|
| 1 | Valid JWT + valid body `{"name":"widget"}` | 201 |
| 2 | No JWT header | 401 |
| 3 | Expired JWT | 401 |
| 4 | Valid JWT + invalid body `{"wrong_field":"x"}` | 400 |
| 5 | Valid JWT + unknown path `/nonexistent` | 404 |
| 6 | Valid JWT + body > 1 MiB | 413 |

Run: `bash scripts/demo.sh`

---

## Demo OpenAPI Spec (registered in Apicurio)

```yaml
openapi: "3.0.0"
info:
  title: Demo API
  version: "1.0.0"
paths:
  /items:
    post:
      operationId: createItem
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [name]
              properties:
                name: { type: string, minLength: 1, maxLength: 100 }
                description: { type: string }
      responses:
        "201": { description: Created }
  /items/{id}:
    get:
      operationId: getItem
      parameters:
        - { name: id, in: path, required: true, schema: { type: string } }
      responses:
        "200": { description: OK }
```

---

## Verification Steps

1. `kubectl --context ingress-cluster get nodes` — cluster healthy
2. `kubectl --context workload-cluster get nodes` — cluster healthy
3. `istioctl --context ingress-cluster remote-clusters` — workload-cluster: synced
4. `curl http://<apicurio-clusterip>:8080/apis/registry/v2/groups/demo/artifacts` — returns demo-api
5. `kubectl --context ingress-cluster -n ext-authz logs deploy/ext-authz` — "listening on :9000"
6. `curl http://<jwt-mock-clusterip>:8080/.well-known/jwks.json` — valid JWKS
7. `bash scripts/demo.sh` — all 6 scenarios pass

---

## File Map

```
terraform/               Terraform-only infrastructure + Kubernetes resources
  main.tf                Root module, provider config, null_resource image builds
  variables.tf           project_id, region, cluster names, node types
  outputs.tf             ingress_lb_ip, cluster endpoints, ca_cert
  terraform.tfvars.example
  modules/
    vpc/                 VPC, subnets, firewall rules
    gke/                 GKE cluster + node pool (used ×2)
    artifact-registry/   GCP Artifact Registry
    istio-primary/       istiod + IngressGW + EastWest GW on ingress-cluster
    istio-remote/        Remote secret + remote istiod + EastWest + Internal GW
    cert-manager/        cert-manager Helm + self-signed CA chain + TLS cert
    apicurio/            Apicurio deployment + spec loader Job
    ext-authz/           ExtAuthz deployment + service
    jwt-mock/            JWT mock deployment + service
    demo-app/            httpbin deployment on workload-cluster
    istio-config/        Gateway, VS, RequestAuthentication, AuthorizationPolicy

ext-authz/               Go gRPC ExtAuthz service source
  main.go
  go.mod
  Dockerfile

jwt-mock/                Go RS512 JWT issuer source
  main.go
  go.mod
  Dockerfile

scripts/
  demo.sh                6-scenario validation script
```
