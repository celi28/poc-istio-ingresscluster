terraform {
  required_providers {
    helm    = { source = "hashicorp/helm" }
    kubectl = { source = "gavinbunney/kubectl" }
    time    = { source = "hashicorp/time" }
  }
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true

  set {
    name  = "installCRDs"
    value = "true"
  }
}

# Wait for cert-manager webhook to be ready
resource "time_sleep" "wait_for_cert_manager" {
  depends_on      = [helm_release.cert_manager]
  create_duration = "30s"
}

# Root self-signed ClusterIssuer
resource "kubectl_manifest" "cluster_issuer_selfsigned" {
  yaml_body  = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: selfsigned-root
    spec:
      selfSigned: {}
  YAML
  depends_on = [time_sleep.wait_for_cert_manager]
}

# Self-signed CA certificate
resource "kubectl_manifest" "ca_certificate" {
  yaml_body  = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: demo-ca
      namespace: cert-manager
    spec:
      isCA: true
      secretName: demo-ca-secret
      commonName: demo-ca
      subject:
        organizations:
          - demo
      issuerRef:
        name: selfsigned-root
        kind: ClusterIssuer
      privateKey:
        algorithm: RSA
        size: 4096
  YAML
  depends_on = [kubectl_manifest.cluster_issuer_selfsigned]
}

# CA-backed ClusterIssuer for all demo certificates
resource "kubectl_manifest" "cluster_issuer_ca" {
  yaml_body  = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: demo-ca-issuer
    spec:
      ca:
        secretName: demo-ca-secret
  YAML
  depends_on = [kubectl_manifest.ca_certificate]
}

# TLS certificate for IngressGateway
resource "kubectl_manifest" "ingress_tls_certificate" {
  yaml_body  = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: ingress-tls
      namespace: istio-ingress
    spec:
      secretName: ingress-tls-secret
      dnsNames: ${jsonencode(var.ingress_dns_names)}
      issuerRef:
        name: demo-ca-issuer
        kind: ClusterIssuer
      renewBefore: 720h
  YAML
  depends_on = [kubectl_manifest.cluster_issuer_ca]
}

output "ca_issuer_name" {
  value = "demo-ca-issuer"
}
