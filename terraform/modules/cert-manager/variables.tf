variable "cert_manager_version" { type = string; default = "v1.14.5" }
variable "ingress_dns_names"    { type = list(string); default = ["api.demo.local", "grpc.demo.local"] }
