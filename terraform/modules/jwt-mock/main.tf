terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}

resource "kubernetes_namespace" "jwt_mock" {
  metadata {
    name   = "jwt-mock"
    labels = { "istio-injection" = "disabled" }
  }
}

resource "kubernetes_deployment" "jwt_mock" {
  metadata {
    name      = "jwt-mock"
    namespace = kubernetes_namespace.jwt_mock.metadata[0].name
    labels    = { app = "jwt-mock" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "jwt-mock" }
    }

    template {
      metadata {
        labels = { app = "jwt-mock" }
      }

      spec {
        container {
          name  = "jwt-mock"
          image = var.image

          port {
            container_port = 8080
            name           = "http"
          }

          env {
            name  = "LISTEN_ADDR"
            value = ":8080"
          }
          env {
            name  = "ISSUER_URL"
            value = "http://jwt-mock.jwt-mock.svc.cluster.local:8080"
          }

          resources {
            limits   = { memory = "128Mi", cpu = "200m" }
            requests = { memory = "64Mi", cpu = "50m" }
          }

          readiness_probe {
            http_get {
              path = "/.well-known/jwks.json"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "jwt_mock" {
  metadata {
    name      = "jwt-mock"
    namespace = kubernetes_namespace.jwt_mock.metadata[0].name
  }

  spec {
    selector = { app = "jwt-mock" }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

output "jwks_uri" {
  value = "http://jwt-mock.jwt-mock.svc.cluster.local:8080/.well-known/jwks.json"
}

output "issuer_url" {
  value = "http://jwt-mock.jwt-mock.svc.cluster.local:8080"
}

output "token_endpoint" {
  value = "http://jwt-mock.jwt-mock.svc.cluster.local:8080/token"
}
