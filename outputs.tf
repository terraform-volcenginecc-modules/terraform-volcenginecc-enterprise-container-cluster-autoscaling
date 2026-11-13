output "vpc_id" {
  description = "New VPC ID."
  value       = module.network.vpc_id
}

output "subnets" {
  description = "AZ-aware Node/Pod subnet ownership."
  value       = module.network.subnets
}

output "nat_gateway_id" {
  description = "Shared public NAT gateway."
  value       = module.network.nat_gateway_id
}

output "egress" {
  description = "Exactly two outbound EIPs and their subnet/SNAT associations."
  value       = module.network.egress
}

output "cluster_id" {
  description = "VKE cluster ID."
  value       = module.cluster.id
}

output "cluster_status" {
  description = "Service-reported cluster status."
  value       = module.cluster.status
}

output "api_server_endpoints" {
  description = "API endpoints; contains no kubeconfig or credential."
  value       = module.cluster.api_server_endpoints
}

output "nodepools" {
  description = "Fixed pool IDs/status indexed by AZ, plus the shared elastic pool."
  value       = module.nodepools.pools
}

output "addons" {
  description = "Terraform-managed optional addons plus read-only platform and reconciled Required addons."
  value       = module.addons.addons
}

output "alb_id" {
  description = "Existing ALB ID to bind to a manually created ALBInstance."
  value       = module.alb.id
}

output "alb_dns_name" {
  description = "Public ALB DNS name; listeners and forwarding rules require ALBInstance/Ingress."
  value       = module.alb.dns_name
}

output "alb_instance_manifest" {
  description = "Manual kubectl manifest binding the Terraform ALB to the Ingress controller."
  value = yamlencode({
    apiVersion = "loadbalancer.vke.volcengine.com/v1beta1"
    kind       = "ALBInstance"
    metadata   = { name = "enterprise-alb" }
    spec = {
      instanceID           = module.alb.id
      blockCascadeDeletion = true
      listeners            = [{ protocol = "HTTP", port = 80 }]
    }
  })
}
