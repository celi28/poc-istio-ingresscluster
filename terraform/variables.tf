variable "project_id" {
  type        = string
  description = "GCP project ID"
  default     = "gcp-poc-prod-cc"
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "ingress_cluster_name" {
  type    = string
  default = "ingress-cluster"
}

variable "workload_cluster_name" {
  type    = string
  default = "workload-cluster"
}

variable "ingress_node_type" {
  type    = string
  default = "e2-standard-4"
}

variable "workload_node_type" {
  type    = string
  default = "e2-standard-2"
}

variable "ingress_node_count" {
  type    = number
  default = 2
}

variable "workload_node_count" {
  type    = number
  default = 2
}

variable "ext_authz_image_tag" {
  type    = string
  default = "latest"
}

variable "jwt_mock_image_tag" {
  type    = string
  default = "latest"
}

variable "istio_version" {
  type    = string
  default = "1.21.0"
}
