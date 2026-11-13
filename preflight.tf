# Terraform resolves defaults, tfvars and platform inputs before invoking this
# read-only check. Its postcondition stops planning before any cloud creation.
locals {
  preflight_configuration = {
    region                          = var.region
    zones                           = [for zone in var.zones : zone.zone_id]
    kubernetes_version              = var.kubernetes_version
    kubernetes_version_confirmation = var.kubernetes_version_confirmation
    instance_types                  = var.instance_types
    image_id                        = var.image_id
    system_volume_type              = var.system_volume_type
    addon_versions                  = var.addon_versions
    required_addons                 = var.required_addons
    manage_cluster_autoscaler       = var.manage_cluster_autoscaler
  }
}

data "external" "preflight" {
  program = ["python3", "${path.module}/scripts/preflight.py", "--external"]
  query = {
    configuration = jsonencode(local.preflight_configuration)
  }

  lifecycle {
    postcondition {
      condition     = self.result.passed == "true"
      error_message = "Availability preflight failed: ${self.result.errors}"
    }
  }
}
