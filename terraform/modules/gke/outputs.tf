output "cluster_name"       { value = google_container_cluster.cluster.name }
output "endpoint"           { value = google_container_cluster.cluster.endpoint }
output "ca_certificate"     { value = google_container_cluster.cluster.master_auth[0].cluster_ca_certificate }
output "cluster_id"         { value = google_container_cluster.cluster.id }
