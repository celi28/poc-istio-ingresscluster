resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = var.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "ingress" {
  project       = var.project_id
  name          = "ingress-subnet"
  network       = google_compute_network.vpc.self_link
  region        = var.region
  ip_cidr_range = "10.0.0.0/20"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.100.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.200.0.0/20"
  }
}

resource "google_compute_subnetwork" "workload" {
  project       = var.project_id
  name          = "workload-subnet"
  network       = google_compute_network.vpc.self_link
  region        = var.region
  ip_cidr_range = "10.1.0.0/20"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.101.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.201.0.0/20"
  }
}

# Allow external HTTPS and gRPC traffic to ingress-cluster nodes
resource "google_compute_firewall" "allow_external_ingress" {
  project = var.project_id
  name    = "allow-external-ingress"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["443", "50051"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ingress-cluster"]
}

# Allow east-west gateway traffic between clusters (port 15443)
resource "google_compute_firewall" "allow_east_west" {
  project = var.project_id
  name    = "allow-east-west-gateway"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["15443"]
  }
  source_ranges = ["10.0.0.0/20", "10.1.0.0/20"]
}

# Allow ExtAuthz gRPC within ingress-cluster subnet
resource "google_compute_firewall" "allow_ext_authz" {
  project = var.project_id
  name    = "allow-ext-authz-grpc"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["9000"]
  }
  source_ranges = ["10.0.0.0/20"]
}

# Allow internal GKE node communication (required for pods cross-node)
resource "google_compute_firewall" "allow_internal" {
  project = var.project_id
  name    = "allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
  source_ranges = ["10.0.0.0/8", "172.16.0.0/12"]
}
