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

# ── 0. Ensure Application Default Credentials are configured ─────────────────
# Terraform's google provider uses ADC — separate from the gcloud CLI session.
#
# Option A (service account key file — recommended for CI / non-interactive):
#   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa-key.json
#   bash scripts/bootstrap.sh
#
# Option B (interactive Cloud Shell user account):
#   Just run the script; it will open the ADC browser login.
echo "[0/7] Configuring Application Default Credentials..."
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
  echo "  Service account key: $GOOGLE_APPLICATION_CREDENTIALS"
  # Activate for gcloud CLI commands too (e.g. gcloud builds submit)
  gcloud auth activate-service-account \
    --key-file="$GOOGLE_APPLICATION_CREDENTIALS" \
    --project="$PROJECT" --quiet
  echo "  ADC will use GOOGLE_APPLICATION_CREDENTIALS (set in environment)."
else
  echo "  No GOOGLE_APPLICATION_CREDENTIALS — using user ADC login."
  gcloud auth application-default login --quiet
fi
echo "ADC configured."
echo ""

# ── 1. Set GCP project ────────────────────────────────────────────────────────
echo "[1/7] Configuring gcloud project..."
gcloud config set project "$PROJECT"

# ── 2. Enable required GCP APIs ───────────────────────────────────────────────
echo "[2/7] Enabling GCP APIs (this may take a minute)..."
gcloud services enable \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project "$PROJECT" \
  --quiet

echo "APIs enabled."

# ── 3. Grant Cloud Build SA access to Artifact Registry ──────────────────────
# Cloud Build needs write access to push images.
echo "[3/7] Granting Cloud Build service account Artifact Registry access..."
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format="value(projectNumber)")
CB_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${CB_SA}" \
  --role="roles/artifactregistry.writer" \
  --quiet 2>/dev/null || true
echo "IAM binding done."

# ── 4. Vendor Go dependencies (needed before Docker builds) ───────────────────
echo "[4/7] Resolving Go dependencies..."
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
