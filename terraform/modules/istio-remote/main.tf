terraform {
  required_providers {
    helm       = { source = "hashicorp/helm" }
    kubernetes = { source = "hashicorp/kubernetes" }
    kubectl    = { source = "gavinbunney/kubectl" }
  }
}

data "google_client_config" "default" {}

# Remote secret: tells istiod on ingress-cluster how to reach workload-cluster
locals {
  remote_kubeconfig = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = "workload"
    clusters = [{
      name = "workload"
      cluster = {
        server                     = "https://${var.workload_cluster_endpoint}"
        certificate-authority-data = var.workload_cluster_ca_cert
      }
    }]
    users = [{
      name = "workload"
      user = { token = data.google_client_config.default.access_token }
    }]
    contexts = [{
      name = "workload"
      context = { cluster = "workload", user = "workload" }
    }]
  })

  istiod_remote_values = <<-YAML
    global:
      meshID: mesh1
      multiCluster:
        clusterName: workload-cluster
      network: workload-network
      remotePilotAddress: ${var.istiod_remote_address}
    pilot:
      enabled: false
  YAML

  eastwest_gateway_workload_values = <<-YAML
    name: istio-eastwestgateway
    labels:
      app: istio-eastwestgateway
      istio: eastwestgateway
      topology.istio.io/network: workload-network
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

  internal_gateway_values = <<-YAML
    name: istio-internalgateway
    labels:
      app: istio-internalgateway
      istio: internalgateway
    service:
      type: LoadBalancer
      annotations:
        networking.gke.io/load-balancer-type: "Internal"
        networking.gke.io/internal-load-balancer-allow-global-access: "false"
      loadBalancerSourceRanges:
        - "10.0.0.0/8"
        - "172.16.0.0/12"
      ports:
        - name: http
          port: 80
          targetPort: 8080
          protocol: TCP
        - name: https
          port: 443
          targetPort: 8443
          protocol: TCP
        - name: grpc
          port: 50051
          targetPort: 50051
          protocol: TCP
  YAML
}

# Applied to ingress-cluster (caller must set provider alias accordingly)
resource "kubernetes_secret" "remote_secret" {
  metadata {
    name      = "istio-remote-secret-workload-cluster"
    namespace = "istio-system"
    labels = {
      "istio/multiCluster" = "true"
    }
    annotations = {
      "networking.istio.io/cluster" = "workload-cluster"
    }
  }
  data = {
    config = local.remote_kubeconfig
  }
}

# On workload-cluster: install Istio CRDs
resource "helm_release" "istio_base_workload" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.istio_version
  namespace        = "istio-system"
  create_namespace = true
  wait             = true
}

# On workload-cluster: remote istiod config (no local control plane)
resource "helm_release" "istiod_remote" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version
  namespace  = "istio-system"
  wait       = true
  depends_on = [helm_release.istio_base_workload]

  values = [local.istiod_remote_values]
}

# EastWest gateway on workload-cluster
resource "helm_release" "eastwest_gateway_workload" {
  name       = "istio-eastwestgateway"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = var.istio_version
  namespace  = "istio-system"
  wait       = true
  depends_on = [helm_release.istiod_remote]

  values = [local.eastwest_gateway_workload_values]
}

# EastWest cross-network gateway for workload-cluster
resource "kubectl_manifest" "cross_network_gateway_workload" {
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
  depends_on = [helm_release.eastwest_gateway_workload]
}

# Internal gateway for datacenter traffic (no auth, internal LB only)
resource "helm_release" "internal_gateway" {
  name       = "istio-internalgateway"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = var.istio_version
  namespace  = "istio-internal"
  wait       = true
  depends_on = [helm_release.istiod_remote]

  values = [local.internal_gateway_values]
}

# Enable Istio sidecar injection in workload namespace
resource "kubectl_manifest" "app_namespace" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: app
      labels:
        istio-injection: enabled
  YAML
  depends_on = [helm_release.istiod_remote]
}
