terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ── Infrastructure ────────────────────────────────────────────────────────────

module "vpc" {
  source     = "./modules/vpc"
  project_id = var.project_id
  region     = var.region
}

module "ingress_cluster" {
  source             = "./modules/gke"
  project_id         = var.project_id
  cluster_name       = var.ingress_cluster_name
  zone               = "${var.region}-b"
  network_self_link  = module.vpc.network_self_link
  subnet_self_link   = module.vpc.ingress_subnet_self_link
  machine_type       = var.ingress_node_type
  node_count         = var.ingress_node_count
  network_tag        = "ingress-cluster"
}

module "workload_cluster" {
  source             = "./modules/gke"
  project_id         = var.project_id
  cluster_name       = var.workload_cluster_name
  zone               = "${var.region}-c"
  network_self_link  = module.vpc.network_self_link
  subnet_self_link   = module.vpc.workload_subnet_self_link
  machine_type       = var.workload_node_type
  node_count         = var.workload_node_count
}

module "artifact_registry" {
  source     = "./modules/artifact-registry"
  project_id = var.project_id
  region     = var.region
}

# ── Kubernetes providers — ingress-cluster ────────────────────────────────────

data "google_client_config" "default" {}

provider "helm" {
  alias = "ingress"
  kubernetes {
    host                   = "https://${module.ingress_cluster.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(module.ingress_cluster.ca_certificate)
  }
}

provider "kubernetes" {
  alias                  = "ingress"
  host                   = "https://${module.ingress_cluster.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.ingress_cluster.ca_certificate)
}

provider "kubectl" {
  alias                  = "ingress"
  host                   = "https://${module.ingress_cluster.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.ingress_cluster.ca_certificate)
  load_config_file       = false
}

# ── Kubernetes providers — workload-cluster ───────────────────────────────────

provider "helm" {
  alias = "workload"
  kubernetes {
    host                   = "https://${module.workload_cluster.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(module.workload_cluster.ca_certificate)
  }
}

provider "kubernetes" {
  alias                  = "workload"
  host                   = "https://${module.workload_cluster.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.workload_cluster.ca_certificate)
}

provider "kubectl" {
  alias                  = "workload"
  host                   = "https://${module.workload_cluster.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.workload_cluster.ca_certificate)
  load_config_file       = false
}

# ── Docker image builds ───────────────────────────────────────────────────────

locals {
  ext_authz_image = "${module.artifact_registry.repository_url}/ext-authz:${var.ext_authz_image_tag}"
  jwt_mock_image  = "${module.artifact_registry.repository_url}/jwt-mock:${var.jwt_mock_image_tag}"
}

# Cloud Build is used instead of local Docker to avoid Cloud Shell token limitations.
# gcloud builds submit uploads source to GCS, builds remotely, and pushes to Artifact Registry.
resource "null_resource" "build_ext_authz" {
  depends_on = [module.artifact_registry]

  triggers = {
    src_hash = sha256(join("", [
      for f in sort(fileset("${path.module}/../ext-authz", "**")) :
      filesha256("${path.module}/../ext-authz/${f}")
    ]))
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud builds submit \
        --tag ${local.ext_authz_image} \
        --project ${var.project_id} \
        ${path.module}/../ext-authz
    EOT
  }
}

resource "null_resource" "build_jwt_mock" {
  depends_on = [module.artifact_registry]

  triggers = {
    src_hash = sha256(join("", [
      for f in sort(fileset("${path.module}/../jwt-mock", "**")) :
      filesha256("${path.module}/../jwt-mock/${f}")
    ]))
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud builds submit \
        --tag ${local.jwt_mock_image} \
        --project ${var.project_id} \
        ${path.module}/../jwt-mock
    EOT
  }
}

# ── Istio — ingress-cluster (primary) ─────────────────────────────────────────

module "istio_primary" {
  source         = "./modules/istio-primary"
  istio_version  = var.istio_version
  depends_on     = [module.ingress_cluster]

  providers = {
    helm    = helm.ingress
    kubectl = kubectl.ingress
  }
}

# ── cert-manager — ingress-cluster ───────────────────────────────────────────

module "cert_manager_ingress" {
  source     = "./modules/cert-manager"
  depends_on = [module.istio_primary]

  providers = {
    helm    = helm.ingress
    kubectl = kubectl.ingress
  }
}

# ── Istio — workload-cluster (remote) ─────────────────────────────────────────
# istiod_remote_address: the east-west gateway IP on ingress-cluster
# We use a data source after istio_primary is deployed to get it.

data "kubernetes_service" "eastwest_gateway_ip" {
  provider = kubernetes.ingress
  metadata {
    name      = "istio-eastwestgateway"
    namespace = "istio-system"
  }
  depends_on = [module.istio_primary]
}

module "istio_remote" {
  source                     = "./modules/istio-remote"
  istio_version              = var.istio_version
  istiod_remote_address      = data.kubernetes_service.eastwest_gateway_ip.status[0].load_balancer[0].ingress[0].ip
  workload_cluster_endpoint  = module.workload_cluster.endpoint
  workload_cluster_ca_cert   = module.workload_cluster.ca_certificate
  project_id                 = var.project_id
  depends_on                 = [module.istio_primary]

  providers = {
    helm       = helm.workload
    kubernetes = kubernetes.ingress   # remote secret goes on ingress-cluster
    kubectl    = kubectl.workload
  }
}

# ── cert-manager — workload-cluster ──────────────────────────────────────────

module "cert_manager_workload" {
  source     = "./modules/cert-manager"
  depends_on = [module.istio_remote]

  providers = {
    helm    = helm.workload
    kubectl = kubectl.workload
  }
}

# ── Apicurio — ingress-cluster ────────────────────────────────────────────────

module "apicurio" {
  source     = "./modules/apicurio"
  depends_on = [module.istio_primary]

  providers = {
    kubernetes = kubernetes.ingress
  }
}

# ── JWT Mock — ingress-cluster ────────────────────────────────────────────────

module "jwt_mock" {
  source     = "./modules/jwt-mock"
  image      = local.jwt_mock_image
  depends_on = [null_resource.build_jwt_mock, module.istio_primary]

  providers = {
    kubernetes = kubernetes.ingress
  }
}

# ── ExtAuthz — ingress-cluster ────────────────────────────────────────────────

module "ext_authz" {
  source       = "./modules/ext-authz"
  image        = local.ext_authz_image
  apicurio_url = module.apicurio.apicurio_service_url
  depends_on   = [null_resource.build_ext_authz, module.apicurio]

  providers = {
    kubernetes = kubernetes.ingress
  }
}

# ── Demo App — workload-cluster ───────────────────────────────────────────────

module "demo_app" {
  source     = "./modules/demo-app"
  depends_on = [module.istio_remote]

  providers = {
    kubernetes = kubernetes.workload
    kubectl    = kubectl.workload
  }
}

# ── Istio security config — ingress-cluster ───────────────────────────────────

module "istio_config" {
  source          = "./modules/istio-config"
  jwt_issuer_url  = module.jwt_mock.issuer_url
  jwt_jwks_uri    = module.jwt_mock.jwks_uri
  jwt_audience    = "api.demo.local"
  api_host        = "api.demo.local"
  depends_on      = [module.istio_primary, module.ext_authz, module.jwt_mock, module.cert_manager_ingress]

  providers = {
    kubectl = kubectl.ingress
  }
}

# ── PeerAuthentication PERMISSIVE — workload-cluster mesh-wide ────────────────

resource "kubectl_manifest" "peer_auth_workload_mesh" {
  provider = kubectl.workload
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
  depends_on = [module.istio_remote]
}
