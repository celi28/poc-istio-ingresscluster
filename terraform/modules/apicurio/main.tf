terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}

resource "kubernetes_namespace" "apicurio" {
  metadata {
    name = "apicurio"
    labels = {
      "istio-injection" = "disabled"
    }
  }
}

resource "kubernetes_deployment" "apicurio" {
  metadata {
    name      = "apicurio-registry"
    namespace = kubernetes_namespace.apicurio.metadata[0].name
    labels    = { app = "apicurio-registry" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "apicurio-registry" }
    }

    template {
      metadata {
        labels = { app = "apicurio-registry" }
      }

      spec {
        container {
          name  = "apicurio"
          image = "quay.io/apicurio/apicurio-registry-mem:${var.apicurio_version}"

          port {
            container_port = 8080
            name           = "http"
          }

          resources {
            limits = {
              memory = "512Mi"
              cpu    = "500m"
            }
            requests = {
              memory = "256Mi"
              cpu    = "100m"
            }
          }

          readiness_probe {
            http_get {
              path = "/health/ready"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 5
          }

          liveness_probe {
            http_get {
              path = "/health/live"
              port = 8080
            }
            initial_delay_seconds = 15
            period_seconds        = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "apicurio" {
  metadata {
    name      = "apicurio-registry"
    namespace = kubernetes_namespace.apicurio.metadata[0].name
  }

  spec {
    selector = { app = "apicurio-registry" }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

# ConfigMap holding the demo OpenAPI spec to load into Apicurio
resource "kubernetes_config_map" "openapi_spec" {
  metadata {
    name      = "demo-openapi-spec"
    namespace = kubernetes_namespace.apicurio.metadata[0].name
  }

  data = {
    "demo-api-v1.json" = jsonencode({
      openapi = "3.0.0"
      info = {
        title   = "Demo API"
        version = "1.0.0"
      }
      paths = {
        "/post" = {
          post = {
            operationId = "createItem"
            requestBody = {
              required = true
              content = {
                "application/json" = {
                  schema = {
                    type     = "object"
                    required = ["name"]
                    properties = {
                      name        = { type = "string", minLength = 1, maxLength = 100 }
                      description = { type = "string" }
                    }
                    additionalProperties = false
                  }
                }
              }
            }
            responses = {
              "200" = { description = "Created" }
            }
          }
        }
        "/get" = {
          get = {
            operationId = "listItems"
            responses = {
              "200" = { description = "OK" }
            }
          }
        }
        "/status/{code}" = {
          get = {
            operationId = "getStatus"
            parameters = [{
              name     = "code"
              in       = "path"
              required = true
              schema   = { type = "integer" }
            }]
            responses = {
              "200" = { description = "OK" }
            }
          }
        }
      }
    })
  }
}

# Job to pre-load demo spec into Apicurio on startup
resource "kubernetes_job" "load_spec" {
  metadata {
    name      = "load-openapi-spec"
    namespace = kubernetes_namespace.apicurio.metadata[0].name
  }

  spec {
    template {
      metadata {}
      spec {
        restart_policy = "OnFailure"

        container {
          name  = "loader"
          image = "curlimages/curl:8.7.1"

          command = [
            "/bin/sh", "-c",
            <<-EOT
              echo "Waiting for Apicurio to be ready..."
              until curl -sf http://apicurio-registry:8080/health/ready; do sleep 3; done
              echo "Loading demo OpenAPI spec..."
              curl -sf -X POST \
                "http://apicurio-registry:8080/apis/registry/v2/groups/demo/artifacts" \
                -H "Content-Type: application/json" \
                -H "X-Registry-ArtifactId: demo-api" \
                -H "X-Registry-ArtifactType: OPENAPI" \
                -d @/spec/demo-api-v1.json
              echo "Spec loaded successfully"
            EOT
          ]

          volume_mount {
            name       = "spec"
            mount_path = "/spec"
          }
        }

        volume {
          name = "spec"
          config_map {
            name = kubernetes_config_map.openapi_spec.metadata[0].name
          }
        }
      }
    }

    backoff_limit = 5
  }

  wait_for_completion = true

  timeouts {
    create = "5m"
    update = "5m"
  }

  depends_on = [kubernetes_deployment.apicurio, kubernetes_service.apicurio]
}

output "apicurio_service_url" {
  value = "http://apicurio-registry.apicurio.svc.cluster.local:8080"
}
