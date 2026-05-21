resource "google_container_cluster" "cluster" {
  project  = var.project_id
  name     = var.cluster_name
  location = var.zone

  network    = var.network_self_link
  subnetwork = var.subnet_self_link

  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Required for Istio CNI
  datapath_provider = "LEGACY_DATAPATH"

  release_channel {
    channel = "REGULAR"
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

resource "google_container_node_pool" "nodes" {
  project    = var.project_id
  cluster    = google_container_cluster.cluster.name
  location   = var.zone
  name       = "${var.cluster_name}-nodes"
  node_count = var.node_count

  node_config {
    machine_type = var.machine_type
    disk_size_gb = 50
    disk_type    = "pd-ssd"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    dynamic "taint" {
      for_each = var.network_tag != "" ? [1] : []
      content {
        key    = "node-role"
        value  = var.network_tag
        effect = "NO_SCHEDULE"
      }
    }

    tags = var.network_tag != "" ? [var.network_tag] : []
  }

  autoscaling {
    min_node_count = var.node_count
    max_node_count = var.node_count + 2
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
