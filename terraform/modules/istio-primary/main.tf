terraform {
  required_providers {
    helm   = { source = "hashicorp/helm" }
    kubectl = { source = "gavinbunney/kubectl" }
  }
}

locals {
  istiod_values = <<-YAML
    meshConfig:
      accessLogFile: /dev/stdout
      extensionProviders:
        - name: ext-authz-schema
          envoyExtAuthzGrpc:
            service: ${var.ext_authz_service_fqdn}
            port: 9000
            timeout: 5s
            statusOnError: DENY
    global:
      meshID: mesh1
      multiCluster:
        clusterName: ingress-cluster
      network: ingress-network
    pilot:
      env:
        PILOT_ENABLE_WORKLOAD_ENTRY_AUTOREGISTRATION: "true"
  YAML

  ingress_gateway_values = <<-YAML
    labels:
      app: istio-ingressgateway
      istio: ingressgateway
    service:
      type: LoadBalancer
      ports:
        - name: https
          port: 443
          targetPort: 8443
          protocol: TCP
        - name: grpc-tls
          port: 50051
          targetPort: 50051
          protocol: TCP
  YAML

  eastwest_gateway_values = <<-YAML
    name: istio-eastwestgateway
    labels:
      app: istio-eastwestgateway
      istio: eastwestgateway
      topology.istio.io/network: ingress-network
    env:
      ISTIO_META_ROUTER_MODE: sni-dnat
    service:
      type: LoadBalancer
      annotations:
        networking.gke.io/load-balancer-type: "Internal"
      ports:
        - name: tls
          port: 15443
          targetPort: 15443
          protocol: TCP
  YAML
}

# 1. Istio CRDs
resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.istio_version
  namespace        = "istio-system"
  create_namespace = true
  wait             = true
}

# 2. istiod — primary control plane
resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version
  namespace  = "istio-system"
  wait       = true
  depends_on = [helm_release.istio_base]

  values = [local.istiod_values]
}

# 3. Create istio-ingress namespace
resource "kubectl_manifest" "istio_ingress_ns" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: istio-ingress
      labels:
        istio-injection: enabled
  YAML
  depends_on = [helm_release.istiod]
}

# 4. IngressGateway — external, public NLB
resource "helm_release" "ingress_gateway" {
  name       = "istio-ingressgateway"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = var.istio_version
  namespace  = "istio-ingress"
  wait       = true
  depends_on = [kubectl_manifest.istio_ingress_ns]

  values = [local.ingress_gateway_values]
}

# 5. EastWest Gateway — internal, for cross-cluster mTLS
resource "helm_release" "eastwest_gateway" {
  name       = "istio-eastwestgateway"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = var.istio_version
  namespace  = "istio-system"
  wait       = true
  depends_on = [helm_release.istiod]

  values = [local.eastwest_gateway_values]
}

# 6. Cross-network Gateway resource for east-west AUTO_PASSTHROUGH
resource "kubectl_manifest" "cross_network_gateway" {
  yaml_body  = <<-YAML
    apiVersion: networking.istio.io/v1beta1
    kind: Gateway
    metadata:
      name: cross-network-gateway
      namespace: istio-system
    spec:
      selector:
        istio: eastwestgateway
      servers:
        - port:
            number: 15443
            name: tls
            protocol: TLS
          tls:
            mode: AUTO_PASSTHROUGH
          hosts:
            - "*.local"
  YAML
  depends_on = [helm_release.eastwest_gateway]
}

output "istiod_service_name" {
  value = "istiod.istio-system.svc.cluster.local"
}
