#!/usr/bin/env bash
# Fetch GKE kubeconfigs and rename contexts to short names.
# Safe to re-run.
set -euo pipefail

PROJECT="gcp-poc-prod-cc"
REGION="europe-west1"

INGRESS_ZONE="${REGION}-b"
WORKLOAD_ZONE="${REGION}-c"
INGRESS_CLUSTER="ingress-cluster"
WORKLOAD_CLUSTER="workload-cluster"

echo "Fetching kubeconfig for $INGRESS_CLUSTER..."
gcloud container clusters get-credentials "$INGRESS_CLUSTER" \
  --zone "$INGRESS_ZONE" \
  --project "$PROJECT"

echo "Fetching kubeconfig for $WORKLOAD_CLUSTER..."
gcloud container clusters get-credentials "$WORKLOAD_CLUSTER" \
  --zone "$WORKLOAD_ZONE" \
  --project "$PROJECT"

# GKE creates contexts named gke_PROJECT_ZONE_CLUSTER — rename to short names.
GKE_INGRESS_CTX="gke_${PROJECT}_${INGRESS_ZONE}_${INGRESS_CLUSTER}"
GKE_WORKLOAD_CTX="gke_${PROJECT}_${WORKLOAD_ZONE}_${WORKLOAD_CLUSTER}"

rename_ctx() {
  local old="$1"
  local new="$2"
  if kubectl config get-contexts "$new" &>/dev/null; then
    echo "Context '$new' already exists — skipping rename."
  else
    kubectl config rename-context "$old" "$new"
    echo "Renamed: $old → $new"
  fi
}

rename_ctx "$GKE_INGRESS_CTX"  "ingress-cluster"
rename_ctx "$GKE_WORKLOAD_CTX" "workload-cluster"

echo ""
echo "Available contexts:"
kubectl config get-contexts
echo ""
echo "Current context: $(kubectl config current-context)"
