terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
    kubectl    = { source = "gavinbunney/kubectl" }
  }
}

resource "kubernetes_deployment" "demo_app" {
  metadata {
    name      = "demo-app"
    namespace = "app"
    labels    = { app = "demo-app", version = "v1" }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = { app = "demo-app" }
    }

    template {
      metadata {
        labels = { app = "demo-app", version = "v1" }
      }

      spec {
        container {
          name  = "httpbin"
          image = "kennethreitz/httpbin:latest"

          port {
            container_port = 80
            name           = "http"
          }

          resources {
            limits   = { memory = "256Mi", cpu = "200m" }
            requests = { memory = "128Mi", cpu = "50m" }
          }

          readiness_probe {
            http_get {
              path = "/get"
              port = 80
            }
            initial_delay_seconds = 10
            period_seconds        = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "demo_app" {
  metadata {
    name      = "demo-app"
    namespace = "app"
    labels    = { app = "demo-app" }
  }

  spec {
    selector = { app = "demo-app" }

    port {
      name        = "http"
      port        = 80
      target_port = 80
    }
  }
}

# PeerAuthentication PERMISSIVE for app namespace
resource "kubectl_manifest" "peer_auth_app" {
  yaml_body = <<-YAML
    apiVersion: security.istio.io/v1beta1
    kind: PeerAuthentication
    metadata:
      name: default
      namespace: app
    spec:
      mtls:
        mode: PERMISSIVE
  YAML
}
