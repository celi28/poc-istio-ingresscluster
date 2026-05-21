# Istio Multi-Cluster Demo — GCP

Demonstrator for `spec-migration-istio-fr.md`.  
Provisions 2 GKE clusters (`europe-west1`) with Istio Primary-Remote, Apicurio Registry, and a custom ExtAuthz gRPC service validating OpenAPI schemas.

**GCP project:** `gcp-poc-prod-cc`

---

## Architecture

```
Internet → [External NLB] → [Istio IngressGateway]
                                  │
                          JWT validation (RS512)   ← jwt-mock
                                  │
                          ExtAuthz schema check    ← ext-authz → Apicurio
                                  │
                          [East-West Gateway :15443]
                                  │ mTLS AUTO_PASSTHROUGH
                          [East-West Gateway :15443]
                                  │
                          [demo-app / httpbin]      (workload-cluster)
```

---

## Quick Start (Cloud Shell)

Open [Cloud Shell](https://shell.cloud.google.com) in the `gcp-poc-prod-cc` project, then:

```bash
# 1. Clone / navigate to the repo
cd ~/kepler/demonstrateur

# 2. Run the full bootstrap (one command)
bash scripts/bootstrap.sh
```

`bootstrap.sh` will:
1. Set gcloud project to `gcp-poc-prod-cc`
2. Enable required GCP APIs
3. Configure Docker for Artifact Registry
4. Run `go mod tidy` for the Go services
5. `terraform init && terraform apply` (~15-20 min)
6. Fetch kubeconfigs and rename kubectl contexts

---

## Run the Demo

```bash
bash scripts/demo.sh
```

Expected output:
```
=== Istio ExtAuthz Schema Validation Demo ===
IngressGateway IP: 34.x.x.x
Fetching tokens from JWT mock...
Tokens acquired.

✓ 1. Valid JWT + valid body → HTTP 200
✓ 2. No JWT header → HTTP 401
✓ 3. Expired JWT → HTTP 401
✓ 4. Valid JWT + invalid body (missing 'name') → HTTP 400
✓ 5. Valid JWT + unknown path /nonexistent → HTTP 404
✓ 6. Valid JWT + body > 1 MiB → HTTP 413

All scenarios passed.
```

---

## Manual Steps

### Verify cluster state

```bash
kubectl --context ingress-cluster get pods -A
kubectl --context workload-cluster get pods -A
```

### Check Istio multi-cluster sync

```bash
# Install istioctl if needed
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.21.0 sh -
export PATH="$PWD/istio-1.21.0/bin:$PATH"

istioctl --context ingress-cluster remote-clusters
# Expected: workload-cluster   synced
```

### Check Apicurio spec loaded

```bash
kubectl --context ingress-cluster -n apicurio port-forward svc/apicurio-registry 8080:8080 &
curl -s http://localhost:8080/apis/registry/v2/groups/demo/artifacts | jq .
```

### Check ExtAuthz logs

```bash
kubectl --context ingress-cluster -n ext-authz logs deploy/ext-authz --tail=20
```

### Get a JWT token manually

```bash
kubectl --context ingress-cluster port-forward -n jwt-mock svc/jwt-mock 18080:8080 &
curl -s -X POST http://localhost:18080/token \
  -H "Content-Type: application/json" \
  -d '{"sub":"user1","aud":"api.demo.local","exp_minutes":60}' | jq .
```

---

## Tear Down

```bash
bash scripts/teardown.sh
```

---

## File Structure

```
terraform/                 Terraform-only provisioning
  main.tf                  Root module (providers, modules, image builds)
  variables.tf             Input variables (project defaults to gcp-poc-prod-cc)
  terraform.tfvars         Active variable values
  modules/
    vpc/                   VPC + subnets + firewall rules
    gke/                   GKE cluster module (used ×2)
    artifact-registry/     GCP Artifact Registry
    istio-primary/         istiod + IngressGW + EastWest GW (ingress-cluster)
    istio-remote/          Remote config + EastWest + InternalGW (workload-cluster)
    cert-manager/          Helm chart + self-signed CA chain
    apicurio/              Apicurio Registry + OpenAPI spec loader
    ext-authz/             ExtAuthz gRPC service deployment
    jwt-mock/              JWT mock service deployment
    demo-app/              httpbin on workload-cluster
    istio-config/          Istio security policies (GW, VS, RequestAuth, AuthzPolicy)

ext-authz/                 Go gRPC ExtAuthz service
  main.go                  Validates requests against Apicurio OpenAPI spec
  go.mod / Dockerfile

jwt-mock/                  Go RS512 JWT issuer
  main.go                  JWKS endpoint + /token endpoint
  go.mod / Dockerfile

scripts/
  bootstrap.sh             Full Cloud Shell setup (APIs → terraform → kubeconfig)
  setup-contexts.sh        Rename GKE kubectl contexts to short names
  demo.sh                  6-scenario validation script
  teardown.sh              terraform destroy
```

---

## Open Decisions (from spec)

| # | Decision | Current demo value |
|---|---|---|
| 1 | Istio model | Primary-Remote |
| 2 | IdP JWT | Mock in-cluster issuer (RS512) |
| 3 | CA backend | cert-manager self-signed |
| 4 | Internal gateway infra | GCP Internal LB annotation |
| 5 | On-prem vs GKE | GKE (`europe-west1`) |
| 6 | OpenAPI spec store | Apicurio in-memory |
| 7 | Observability | None (demo scope) |
