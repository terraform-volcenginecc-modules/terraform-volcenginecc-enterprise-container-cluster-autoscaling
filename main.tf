module "network" {
  source           = "./modules/network"
  name_prefix      = var.name_prefix
  project_name     = var.project_name
  vpc_cidr         = var.vpc_cidr
  zones            = var.zones
  network_valid    = local.network_valid
  nat_spec         = var.nat_spec
  egress_bandwidth = var.egress_bandwidth
  tags             = local.common_tags
  depends_on       = [data.external.preflight]
}

module "cluster" {
  source                           = "./modules/cluster"
  name                             = var.name_prefix
  project_name                     = var.project_name
  kubernetes_version               = var.kubernetes_version
  node_subnet_ids                  = module.network.node_subnet_ids
  pod_subnet_ids                   = module.network.pod_subnet_ids
  service_cidr                     = var.service_cidr
  delete_protection_enabled        = var.vke_delete_protection_enabled
  api_server_public_access_enabled = var.api_server_public_access_enabled
  tags                             = local.common_tags
  # Readiness requires completed EIP binding and SNAT configuration.
  depends_on = [module.network]
}

module "nodepools" {
  source                   = "./modules/nodepools"
  cluster_id               = module.cluster.id
  name_prefix              = var.name_prefix
  project_name             = var.project_name
  node_subnet_ids_by_zone  = module.network.node_subnet_ids_by_zone
  instance_types           = var.instance_types
  image_id                 = var.image_id
  node_login_method        = var.node_login_method
  ssh_key_pair_name        = var.ssh_key_pair_name
  node_password            = var.node_password
  system_volume_size       = var.system_volume_size
  system_volume_type       = var.system_volume_type
  fixed_replicas_by_zone   = var.fixed_replicas_by_zone
  elastic_initial_replicas = var.elastic_initial_replicas
  elastic_min_replicas     = var.elastic_min_replicas
  elastic_max_replicas     = var.elastic_max_replicas
  tags                     = local.common_tags
}

module "addons" {
  source                      = "./modules/addons"
  region                      = var.region
  cluster_id                  = module.cluster.id
  addon_versions              = var.addon_versions
  required_addons             = var.required_addons
  required_addons_script      = abspath("${path.root}/scripts/reconcile-required-addons.py")
  required_addons_nonce       = var.required_addons_reconcile_nonce
  required_addons_timeout     = var.required_addons_timeout_seconds
  manage_cluster_autoscaler   = var.manage_cluster_autoscaler
  scale_down_unneeded_minutes = var.scale_down_unneeded_minutes
  depends_on                  = [module.nodepools]
}

module "alb" {
  source                    = "./modules/alb"
  name                      = "${var.name_prefix}-alb"
  project_name              = var.project_name
  vpc_id                    = module.network.vpc_id
  zone_mappings             = module.network.node_zone_mappings
  bandwidth                 = var.alb_bandwidth
  delete_protection_enabled = var.alb_delete_protection_enabled
  tags                      = local.common_tags
}
