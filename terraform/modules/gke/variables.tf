variable "project_id"        { type = string }
variable "cluster_name"      { type = string }
variable "zone"              { type = string }
variable "network_self_link" { type = string }
variable "subnet_self_link"  { type = string }
variable "pods_range_name" {
  type    = string
  default = "pods"
}
variable "services_range_name" {
  type    = string
  default = "services"
}
variable "machine_type" {
  type    = string
  default = "e2-standard-4"
}
variable "node_count" {
  type    = number
  default = 2
}
variable "network_tag" {
  type    = string
  default = ""
}
