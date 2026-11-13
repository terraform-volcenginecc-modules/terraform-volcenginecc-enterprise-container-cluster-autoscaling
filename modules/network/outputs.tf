output "vpc_id" {
  description = "New VPC ID."
  value       = volcenginecc_vpc_vpc.this.id
}
output "nat_gateway_id" {
  description = "Shared public NAT gateway ID."
  value       = volcenginecc_natgateway_ngw.this.id
}
output "node_subnet_ids" {
  description = "Node subnet IDs in caller AZ order."
  value       = [for z in var.zones : volcenginecc_vpc_subnet.node[z.zone_id].id]
}
output "node_subnet_ids_by_zone" {
  description = "Node subnet IDs keyed by AZ; keys are known before subnet creation."
  value       = { for z in var.zones : z.zone_id => volcenginecc_vpc_subnet.node[z.zone_id].id }
}
output "pod_subnet_ids" {
  description = "Pod subnet IDs in caller AZ order."
  value       = [for z in var.zones : volcenginecc_vpc_subnet.pod[z.zone_id].id]
}
output "node_zone_mappings" {
  description = "Explicit ALB AZ-to-subnet mappings."
  value       = [for z in var.zones : { zone_id = z.zone_id, subnet_id = volcenginecc_vpc_subnet.node[z.zone_id].id }]
}
output "subnets" {
  description = "Actual AZ/CIDR/subnet ownership."
  value = {
    for z in var.zones : z.zone_id => {
      node = { id = volcenginecc_vpc_subnet.node[z.zone_id].id, cidr = z.node_cidr }
      pod  = { id = volcenginecc_vpc_subnet.pod[z.zone_id].id, cidr = z.pod_cidr }
    }
  }
}
output "egress" {
  description = "Role-specific outbound EIPs and SNAT rules."
  value = {
    node = {
      eip_id  = volcenginecc_vpc_eip.node.id
      address = volcenginecc_vpc_eip.node.eip_address
      rules = merge({
        (var.zones[0].zone_id) = volcenginecc_natgateway_snatentry.node_a.id
        (var.zones[1].zone_id) = volcenginecc_natgateway_snatentry.node_b.id
        }, length(var.zones) == 3 ? {
        (var.zones[2].zone_id) = volcenginecc_natgateway_snatentry.node_c[0].id
      } : {})
    }
    pod = {
      eip_id  = volcenginecc_vpc_eip.pod.id
      address = volcenginecc_vpc_eip.pod.eip_address
      rules = merge({
        (var.zones[0].zone_id) = volcenginecc_natgateway_snatentry.pod_a.id
        (var.zones[1].zone_id) = volcenginecc_natgateway_snatentry.pod_b.id
        }, length(var.zones) == 3 ? {
        (var.zones[2].zone_id) = volcenginecc_natgateway_snatentry.pod_c[0].id
      } : {})
    }
  }
}
