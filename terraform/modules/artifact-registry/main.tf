variable "project_id" { type = string }
variable "region"     { type = string }

resource "google_artifact_registry_repository" "demo" {
  project       = var.project_id
  location      = var.region
  repository_id = "demo-images"
  description   = "Docker images for the Istio demo"
  format        = "DOCKER"
}

output "repository_url" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/demo-images"
}
