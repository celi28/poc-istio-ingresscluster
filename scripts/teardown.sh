#!/usr/bin/env bash
# Destroy all demo resources. Irreversible.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

echo "=== Tearing down Istio demo ==="
echo "This will destroy all GCP resources (GKE clusters, VPC, Artifact Registry images)."
read -p "Are you sure? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

cd "$TF_DIR"
terraform destroy -auto-approve

echo ""
echo "All resources destroyed."
