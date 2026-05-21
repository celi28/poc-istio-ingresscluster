terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}

resource "kubernetes_namespace" "ext_authz" {
  metadata {
    name   = "ext-authz"
    labels = { "istio-injection" = "disabled" }
  }
}

resource "kubernetes_deployment" "ext_authz" {
  metadata {
    name      = "ext-authz"
    namespace = kubernetes_namespace.ext_authz.metadata[0].name
    labels    = { app = "ext-authz" }
  }

  spec {
    replicas = 2

    selector {
      match_labels = { app = "ext-authz" }
    }

    template {
      metadata {
        labels = { app = "ext-authz" }
      }

      spec {
        toleration {
          key      = "node-role"
          operator = "Equal"
          value    = "ingress-cluster"
          effect   = "NoSchedule"
        }

        container {
          name  = "ext-authz"
          image = var.image

          port {
            container_port = 9000
            name           = "grpc"
          }

          env {
            name  = "LISTEN_ADDR"
            value = ":9000"
          }
          env {
            name  = "APICURIO_URL"
            value = var.apicurio_url
          }
          env {
            name  = "ARTIFACT_GROUP"
            value = "demo"
          }
          env {
            name  = "ARTIFACT_ID"
            value = "demo-api"
          }
          env {
            name  = "CACHE_TTL"
            value = var.cache_ttl
          }
          env {
            name  = "MAX_BODY_BYTES"
            value = tostring(var.max_body_bytes)
          }

          resources {
            limits   = { memory = "256Mi", cpu = "500m" }
            requests = { memory = "128Mi", cpu = "100m" }
          }

          readiness_probe {
            grpc {
              port = 9000
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          liveness_probe {
            grpc {
              port = 9000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "ext_authz" {
  metadata {
    name      = "ext-authz"
    namespace = kubernetes_namespace.ext_authz.metadata[0].name
  }

  spec {
    selector = { app = "ext-authz" }

    port {
      name        = "grpc"
      port        = 9000
      target_port = 9000
      protocol    = "TCP"
    }
  }
}
