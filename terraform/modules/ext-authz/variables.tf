variable "image" {
  type        = string
  description = "Full image URL including tag"
}
variable "apicurio_url" {
  type = string
}
variable "max_body_bytes" {
  type    = number
  default = 1048576
}
variable "cache_ttl" {
  type    = string
  default = "60s"
}
