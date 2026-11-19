output "pools" {
  description = "Fixed pools keyed by AZ and one shared elastic pool; status comes from provider readback."
  value = {
    fixed = {
      for zone, pool in volcenginecc_vke_node_pool.fixed : zone => {
        id               = pool.id
        status           = pool.status
        zone_id          = zone
        subnet_id        = var.node_subnet_ids_by_zone[zone]
        desired_replicas = pool.auto_scaling.desired_replicas
      }
    }
    elastic = { id = volcenginecc_vke_node_pool.elastic.id, status = volcenginecc_vke_node_pool.elastic.status }
  }
}
