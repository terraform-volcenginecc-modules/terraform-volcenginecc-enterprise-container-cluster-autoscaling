output "id" {
  description = "ALB instance ID."
  value       = volcenginecc_alb_load_balancer.this.id
}
output "dns_name" {
  description = "ALB public DNS name."
  value       = volcenginecc_alb_load_balancer.this.dns_name
}
