locals {
  tags = [for k, v in var.tags : { key = k, value = v }]
  login_valid = var.node_login_method == "SshKeyPair" ? (
    try(length(trimspace(var.ssh_key_pair_name)) > 0, false) && var.node_password == null
    ) : (
    var.ssh_key_pair_name == null && var.node_password != null
  )
  # Type is read-only in the provider schema. Send only the selected credential.
  node_login = var.node_login_method == "Password" ? {
    password          = var.node_password == null ? null : base64encode(var.node_password)
    ssh_key_pair_name = null
    } : {
    password          = null
    ssh_key_pair_name = var.ssh_key_pair_name == null ? null : trimspace(var.ssh_key_pair_name)
  }
  node_config = {
    instance_type_ids     = var.instance_types
    image_id              = var.image_id
    subnet_ids            = [for zone in sort(keys(var.node_subnet_ids_by_zone)) : var.node_subnet_ids_by_zone[zone]]
    instance_charge_type  = "PostPaid"
    project_name          = var.project_name
    public_access_enabled = false
    security = {
      login = local.node_login
    }
    system_volume = { size = var.system_volume_size, type = var.system_volume_type }
    tags          = local.tags
  }
}

resource "volcenginecc_vke_node_pool" "fixed" {
  # AZ keys come from configuration, never from computed subnet IDs.
  for_each = var.fixed_replicas_by_zone

  cluster_id = var.cluster_id
  name       = "${var.name_prefix}-fixed-${each.key}"
  node_config = merge(local.node_config, {
    subnet_ids = [lookup(var.node_subnet_ids_by_zone, each.key, null)]
  })
  auto_scaling = {
    enabled          = false
    desired_replicas = each.value
  }
  kubernetes_config = {
    labels = [{ key = "workload-pool", value = "fixed" }]
  }
  tags = local.tags
  lifecycle {
    precondition {
      condition     = local.login_valid
      error_message = "SshKeyPair requires a non-empty ssh_key_pair_name and node_password=null; Password requires node_password and ssh_key_pair_name=null."
    }
    precondition {
      condition     = toset(keys(var.fixed_replicas_by_zone)) == toset(keys(var.node_subnet_ids_by_zone))
      error_message = "Fixed replica AZ keys must exactly match the Node subnet AZ keys."
    }
    precondition {
      condition     = length(var.instance_types) == 1 || try(length(trimspace(var.image_id)) > 0, false)
      error_message = "Multiple instance types require a common supported image_id."
    }
  }
}

resource "volcenginecc_vke_node_pool" "elastic" {
  cluster_id  = var.cluster_id
  name        = "${var.name_prefix}-elastic"
  node_config = local.node_config
  auto_scaling = {
    enabled          = true
    desired_replicas = var.elastic_initial_replicas
    min_replicas     = var.elastic_min_replicas
    max_replicas     = var.elastic_max_replicas
    subnet_policy    = "ZoneBalance"
  }
  kubernetes_config = {
    labels = [{ key = "workload-pool", value = "elastic" }]
  }
  tags       = local.tags
  depends_on = [volcenginecc_vke_node_pool.fixed]
  lifecycle {
    precondition {
      condition     = local.login_valid
      error_message = "SshKeyPair requires a non-empty ssh_key_pair_name and node_password=null; Password requires node_password and ssh_key_pair_name=null."
    }
    # Do not reset the autoscaler's live desired count during unrelated applies.
    ignore_changes = [auto_scaling.desired_replicas]
    precondition {
      condition     = toset(keys(var.fixed_replicas_by_zone)) == toset(keys(var.node_subnet_ids_by_zone))
      error_message = "Fixed replica AZ keys must exactly match the Node subnet AZ keys."
    }
    precondition {
      condition = (
        var.elastic_min_replicas >= 0 &&
        var.elastic_min_replicas <= var.elastic_initial_replicas &&
        var.elastic_initial_replicas <= var.elastic_max_replicas &&
        var.elastic_max_replicas <= 2000 &&
        alltrue([for n in [var.elastic_min_replicas, var.elastic_initial_replicas, var.elastic_max_replicas] : floor(n) == n])
      )
      error_message = "Elastic counts must be integers satisfying 0 <= min <= initial <= max <= 2000."
    }
    precondition {
      condition     = length(var.instance_types) == 1 || try(length(trimspace(var.image_id)) > 0, false)
      error_message = "Multiple instance types require a common supported image_id."
    }
  }
}
