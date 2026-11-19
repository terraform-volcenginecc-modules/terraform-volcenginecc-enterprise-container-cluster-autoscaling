output "addons" {
  description = "Service-reported component IDs and status."
  value = merge({
    prometheus = { id = volcenginecc_vke_addon.prometheus.id, status = volcenginecc_vke_addon.prometheus.status }
    logging    = { id = volcenginecc_vke_addon.logging.id, status = volcenginecc_vke_addon.logging.status }
    npd        = { id = volcenginecc_vke_addon.npd.id, status = volcenginecc_vke_addon.npd.status }
    alb        = { id = data.volcenginecc_vke_addon.alb.id, status = data.volcenginecc_vke_addon.alb.status }
    platform = {
      for name, addon in local.platform_addons :
      name => { id = addon.id, version = addon.version, status = addon.status }
    }
    required = {
      for name, addon in local.required_addon_readback :
      name => { id = addon.id, version = addon.version, status = addon.status }
    }
    }, var.manage_cluster_autoscaler ? {
    autoscaler = { id = volcenginecc_vke_addon.autoscaler[0].id, status = volcenginecc_vke_addon.autoscaler[0].status }
  } : {})
}
