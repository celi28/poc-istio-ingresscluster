variable "istio_version" { type = string }
variable "ext_authz_service_fqdn" {
  type    = string
  default = "ext-authz.ext-authz.svc.cluster.local"
}
