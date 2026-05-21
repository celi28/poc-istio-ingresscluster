output "ingress_cluster_endpoint" {
  value       = module.ingress_cluster.endpoint
  description = "GKE API endpoint for ingress-cluster"
}

output "workload_cluster_endpoint" {
  value       = module.workload_cluster.endpoint
  description = "GKE API endpoint for workload-cluster"
}

output "artifact_registry_url" {
  value       = module.artifact_registry.repository_url
  description = "Artifact Registry base URL for Docker images"
}

output "ingress_lb_ip" {
  value       = "Run: kubectl --context ingress-cluster -n istio-ingress get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
  description = "Get the public IP of the IngressGateway after deploy"
}

output "get_kubeconfig_ingress" {
  value       = "gcloud container clusters get-credentials ${var.ingress_cluster_name} --zone ${var.region}-b --project ${var.project_id}"
  description = "Command to fetch kubeconfig for ingress-cluster"
}

output "get_kubeconfig_workload" {
  value       = "gcloud container clusters get-credentials ${var.workload_cluster_name} --zone ${var.region}-c --project ${var.project_id}"
  description = "Command to fetch kubeconfig for workload-cluster"
}
