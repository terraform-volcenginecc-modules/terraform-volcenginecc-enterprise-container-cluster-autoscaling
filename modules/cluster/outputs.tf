output "id" {
  description = "VKE cluster identifier."
  value       = volcenginecc_vke_cluster.this.id
}
output "status" {
  description = "VKE-reported cluster status."
  value       = volcenginecc_vke_cluster.this.status
}
output "api_server_endpoints" {
  description = "Private/public API endpoints without kubeconfig."
  value       = volcenginecc_vke_cluster.this.cluster_config.api_server_endpoints
}
