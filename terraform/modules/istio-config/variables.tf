variable "jwt_issuer_url" { type = string }
variable "jwt_jwks_uri"   { type = string }
variable "jwt_audience" {
  type    = string
  default = "api.demo.local"
}
variable "api_host" {
  type    = string
  default = "api.demo.local"
}
