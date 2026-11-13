resource "volcenginecc_alb_load_balancer" "this" {
  load_balancer_name         = var.name
  type                       = "public"
  vpc_id                     = var.vpc_id
  address_ip_version         = "IPv4"
  load_balancer_billing_type = 1
  load_balancer_edition      = "Standard"
  project_name               = var.project_name
  zone_mappings              = var.zone_mappings
  delete_protection          = var.delete_protection_enabled ? "on" : "off"
  eip_billing_config = {
    billing_type = 3
    bandwidth    = var.bandwidth
    isp          = "BGP"
  }
  tags = [for k, v in var.tags : { key = k, value = v }]
  # Controller-owned listeners, server groups and rules are deliberately
  # configured through a manual ALBInstance, avoiding dual ownership.
  # Provider 0.0.74 can propose replacement on unrelated updates because
  # optional computed children in this create-only object become unknown.
  # Even ignore_changes does not fix that provider plan. Use the guarded
  # scripts/prepare-destroy.py exit procedure; do not apply a replacement
  # merely to disable protection. See docs/REMEDIATION.zh-CN.md.
}
