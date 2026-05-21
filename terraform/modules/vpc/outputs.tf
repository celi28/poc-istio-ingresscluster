output "network_self_link"          { value = google_compute_network.vpc.self_link }
output "network_name"               { value = google_compute_network.vpc.name }
output "ingress_subnet_self_link"   { value = google_compute_subnetwork.ingress.self_link }
output "ingress_subnet_name"        { value = google_compute_subnetwork.ingress.name }
output "workload_subnet_self_link"  { value = google_compute_subnetwork.workload.self_link }
output "workload_subnet_name"       { value = google_compute_subnetwork.workload.name }
