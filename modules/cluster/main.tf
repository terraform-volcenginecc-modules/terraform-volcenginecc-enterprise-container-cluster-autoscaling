resource "volcenginecc_vke_cluster" "this" {
  name                      = var.name
  description               = "Multi-AZ enterprise container infrastructure"
  project_name              = var.project_name
  kubernetes_version_create = var.kubernetes_version
  delete_protection_enabled = var.delete_protection_enabled
  tags                      = [for k, v in var.tags : { key = k, value = v }]
  cluster_config = {
    subnet_ids                             = var.node_subnet_ids
    api_server_public_access_enabled       = var.api_server_public_access_enabled
    resource_public_access_default_enabled = false
  }
  pods_config = {
    pod_network_mode = "VpcCniShared"
    vpc_cni_config = {
      subnet_ids        = var.pod_subnet_ids
      trunk_eni_enabled = false
    }
  }
  services_config = {
    service_cidrsv_4 = [var.service_cidr]
  }
}
