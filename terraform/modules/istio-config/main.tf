terraform {
  required_providers {
    kubectl = { source = "gavinbunney/kubectl" }
  }
}

# External Gateway — HTTPS termination on ingress-cluster
resource "kubectl_manifest" "external_gateway" {
  yaml_body = <<-YAML
    apiVersion: networking.istio.io/v1beta1
    kind: Gateway
    metadata:
      name: external-gateway
      namespace: istio-ingress
    spec:
      selector:
        istio: ingressgateway
      servers:
        - port:
            number: 443
            name: https
            protocol: HTTPS
          tls:
            mode: SIMPLE
            credentialName: ingress-tls-secret
          hosts:
            - "${var.api_host}"
  YAML
}

# RequestAuthentication — RS512 JWT validation via mock issuer
resource "kubectl_manifest" "request_authentication" {
  yaml_body = <<-YAML
    apiVersion: security.istio.io/v1beta1
    kind: RequestAuthentication
    metadata:
      name: jwt-external
      namespace: istio-ingress
    spec:
      selector:
        matchLabels:
          app: istio-ingressgateway
      jwtRules:
        - issuer: "${var.jwt_issuer_url}"
          jwksUri: "${var.jwt_jwks_uri}"
          audiences:
            - "${var.jwt_audience}"
          forwardOriginalToken: false
  YAML
}

# AuthorizationPolicy — deny requests without a valid JWT
resource "kubectl_manifest" "authz_require_jwt" {
  yaml_body  = <<-YAML
    apiVersion: security.istio.io/v1beta1
    kind: AuthorizationPolicy
    metadata:
      name: require-jwt
      namespace: istio-ingress
    spec:
      selector:
        matchLabels:
          app: istio-ingressgateway
      action: DENY
      rules:
        - from:
            - source:
                notRequestPrincipals: ["*"]
          to:
            - operation:
                hosts: ["${var.api_host}"]
  YAML
  depends_on = [kubectl_manifest.request_authentication]
}

# AuthorizationPolicy — CUSTOM action to call ExtAuthz for schema validation
resource "kubectl_manifest" "authz_ext_authz_schema" {
  yaml_body  = <<-YAML
    apiVersion: security.istio.io/v1beta1
    kind: AuthorizationPolicy
    metadata:
      name: ext-authz-schema
      namespace: istio-ingress
    spec:
      selector:
        matchLabels:
          app: istio-ingressgateway
      action: CUSTOM
      provider:
        name: ext-authz-schema
      rules:
        - to:
            - operation:
                hosts: ["${var.api_host}"]
  YAML
  depends_on = [kubectl_manifest.authz_require_jwt]
}

# VirtualService — route api.demo.local to demo-app on workload-cluster
resource "kubectl_manifest" "virtual_service_api" {
  yaml_body  = <<-YAML
    apiVersion: networking.istio.io/v1beta1
    kind: VirtualService
    metadata:
      name: api-route
      namespace: istio-ingress
    spec:
      hosts:
        - "${var.api_host}"
      gateways:
        - external-gateway
      http:
        - route:
            - destination:
                host: demo-app.app.svc.cluster.local
                port:
                  number: 80
  YAML
  depends_on = [kubectl_manifest.external_gateway]
}

# PeerAuthentication PERMISSIVE — mesh-wide on ingress-cluster
resource "kubectl_manifest" "peer_auth_ingress" {
  yaml_body = <<-YAML
    apiVersion: security.istio.io/v1beta1
    kind: PeerAuthentication
    metadata:
      name: default
      namespace: istio-system
    spec:
      mtls:
        mode: PERMISSIVE
  YAML
}

# ServiceEntry — allows ingress-cluster to resolve demo-app on workload-cluster
resource "kubectl_manifest" "service_entry_demo_app" {
  yaml_body  = <<-YAML
    apiVersion: networking.istio.io/v1beta1
    kind: ServiceEntry
    metadata:
      name: demo-app-workload
      namespace: istio-ingress
    spec:
      hosts:
        - demo-app.app.svc.cluster.local
      location: MESH_INTERNAL
      ports:
        - number: 80
          name: http
          protocol: HTTP
      resolution: DNS
  YAML
  depends_on = [kubectl_manifest.virtual_service_api]
}
