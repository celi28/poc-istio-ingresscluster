#!/usr/bin/env bash
# Bootstrap the Istio multi-cluster demo from GCP Cloud Shell.
# Run from the repository root: bash scripts/bootstrap.sh
set -euo pipefail

PROJECT="gcp-poc-prod-cc"
REGION="europe-west1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

echo "=== Istio Multi-Cluster Demo Bootstrap ==="
echo "Project : $PROJECT"
echo "Region  : $REGION"
echo ""

# ── 1. Set GCP project ────────────────────────────────────────────────────────
echo "[1/6] Configuring gcloud project..."
gcloud config set project "$PROJECT"

# ── 2. Enable required GCP APIs ───────────────────────────────────────────────
echo "[2/6] Enabling GCP APIs (this may take a minute)..."
gcloud services enable \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project "$PROJECT" \
  --quiet

echo "APIs enabled."

# ── 3. Configure Docker auth for Artifact Registry ───────────────────────────
echo "[3/6] Configuring Docker auth for Artifact Registry..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

# ── 4. Vendor Go dependencies (needed before Docker builds) ───────────────────
echo "[4/6] Resolving Go dependencies..."
cd "$REPO_ROOT/ext-authz" && go mod tidy && cd "$REPO_ROOT"
cd "$REPO_ROOT/jwt-mock"  && go mod tidy && cd "$REPO_ROOT"

# ── 5. Terraform init ─────────────────────────────────────────────────────────
echo "[5/7] Running terraform init..."
cd "$TF_DIR"
terraform init -upgrade

# ── 6. Terraform apply ────────────────────────────────────────────────────────
echo "[6/7] Running terraform apply..."
echo "This will take ~15-20 minutes (GKE cluster provisioning)."
echo ""
terraform apply -auto-approve

# ── 7. Configure kubectl contexts ────────────────────────────────────────────
echo "[7/7] Configuring kubectl contexts..."
cd "$REPO_ROOT"
bash scripts/setup-contexts.sh

echo ""
echo "=== Bootstrap complete ==="
echo ""
echo "Run the demo:"
echo "  bash scripts/demo.sh"
