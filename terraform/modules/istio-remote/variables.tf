variable "istio_version" { type = string }
variable "istiod_remote_address" {
  type        = string
  description = "IP or FQDN of primary istiod (east-west GW IP)"
}
variable "workload_cluster_endpoint" { type = string }
variable "workload_cluster_ca_cert" {
  type        = string
  description = "Base64-encoded CA cert of workload cluster"
}
variable "project_id" { type = string }
