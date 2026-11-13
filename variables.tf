variable "region" {
  description = "Target Volcengine region."
  type        = string
  default     = "cn-beijing"
}

variable "name_prefix" {
  description = "Unique environment prefix for resource names."
  type        = string
  default     = "vke"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,35}$", var.name_prefix))
    error_message = "Use 2-36 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "project_name" {
  description = "Existing Volcengine project used by all supported resources."
  type        = string
  default     = "default"
}

variable "tags" {
  description = "User-defined resource tags. No management tags are added automatically."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "vpc_cidr" {
  description = "New VPC IPv4 CIDR. Use a private address range."
  type        = string
  default     = "10.0.0.0/16"
  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "Provide a valid IPv4 CIDR."
  }
}

variable "zones" {
  description = "Two or three target AZs and disjoint Node/Pod CIDRs. Verify service availability first."
  type = list(object({
    zone_id   = string
    node_cidr = string
    pod_cidr  = string
  }))
  default = [
    { zone_id = "cn-beijing-a", node_cidr = "10.0.0.0/24", pod_cidr = "10.0.16.0/20" },
    { zone_id = "cn-beijing-c", node_cidr = "10.0.1.0/24", pod_cidr = "10.0.32.0/20" },
  ]
  validation {
    condition = (
      length(var.zones) >= 2 && length(var.zones) <= 3 &&
      length(distinct([for z in var.zones : z.zone_id])) == length(var.zones) &&
      alltrue([for z in var.zones : can(cidrnetmask(z.node_cidr)) && can(cidrnetmask(z.pod_cidr))])
    )
    error_message = "Specify 2-3 distinct AZs with valid IPv4 Node and Pod CIDRs."
  }
}

variable "service_cidr" {
  description = "Service IPv4 CIDR, disjoint from the VPC and all connected networks."
  type        = string
  default     = "172.22.0.0/22"
  validation {
    condition     = can(cidrnetmask(var.service_cidr))
    error_message = "Provide a valid IPv4 CIDR."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes minor version. Preflight requires a current confirmation that this region permits creating it."
  type        = string
  default     = "1.32"
  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "Use x.xx format, such as 1.32."
  }
}

variable "kubernetes_version_confirmation" {
  description = "Operator confirmation from the target-region VKE create-cluster page or a verified service response. Valid for 24 hours; null blocks deployment."
  type = object({
    region           = string
    version          = string
    resolved_version = string
    verified_at_utc  = string
    source           = string
  })
  default = null
}

variable "vke_delete_protection_enabled" {
  description = "Protect the VKE cluster from deletion. Disable through a reviewed stack update before destroy."
  type        = bool
  default     = true
}

variable "alb_delete_protection_enabled" {
  description = "Protect the ALB from deletion. Keep false for InfraManager because Provider 0.0.74 cannot safely update protection in place."
  type        = bool
  default     = false
}

variable "api_server_public_access_enabled" {
  description = "Expose the Kubernetes API publicly. Prefer private access via VPN or a bastion."
  type        = bool
  default     = false
}

variable "nat_spec" {
  description = "Target-region supported public NAT gateway specification."
  type        = string
  default     = "Small"
  validation {
    condition     = contains(["Small", "Medium", "Large", "Extra_Large_1", "Extra_Large_2"], var.nat_spec)
    error_message = "Unsupported NAT specification."
  }
}

variable "egress_bandwidth" {
  description = "Mbps cap for each of the two traffic-billed outbound EIPs."
  type        = number
  default     = 10
  validation {
    condition     = var.egress_bandwidth >= 1 && var.egress_bandwidth <= 200 && floor(var.egress_bandwidth) == var.egress_bandwidth
    error_message = "Traffic-billed EIP bandwidth must be an integer from 1 to 200 Mbps."
  }
}

variable "alb_bandwidth" {
  description = "Create-time Mbps cap for ALB inbound EIPs. Changing it requires ALB replacement; disable deletion protection separately first."
  type        = number
  default     = 10
  validation {
    condition     = var.alb_bandwidth >= 1 && var.alb_bandwidth <= 200 && floor(var.alb_bandwidth) == var.alb_bandwidth
    error_message = "ALB bandwidth must be an integer from 1 to 200 Mbps."
  }
}

variable "instance_types" {
  description = "1-10 VKE-compatible ECS types available in every selected AZ."
  type        = list(string)
  default     = ["ecs.g4il.4xlarge"]
  nullable    = false
  validation {
    condition = (
      length(var.instance_types) >= 1 && length(var.instance_types) <= 10 &&
      length(distinct(var.instance_types)) == length(var.instance_types) &&
      alltrue([for t in var.instance_types : can(regex("^ecs\\.[a-z0-9]+\\.[a-z0-9]+$", t))])
    )
    error_message = "Provide 1-10 distinct ECS instance type IDs."
  }
}

variable "image_id" {
  description = "Verified VKE-compatible image ID. Null uses the VKE default for a single instance type."
  type        = string
  default     = null
}

variable "ssh_key_pair_name" {
  description = "Existing ECS SSH key pair in the target region. Never provide the private key."
  type        = string
  validation {
    condition     = length(trimspace(var.ssh_key_pair_name)) > 0
    error_message = "An existing regional ECS SSH key pair name is required."
  }
}

variable "system_volume_size" {
  description = "Worker system disk capacity in GiB."
  type        = number
  default     = 80
  validation {
    condition     = var.system_volume_size >= 40 && var.system_volume_size <= 2048 && floor(var.system_volume_size) == var.system_volume_size
    error_message = "Use an integer from 40 to 2048 GiB."
  }
}

variable "system_volume_type" {
  description = "Disk type supported by the selected ECS instance types."
  type        = string
  default     = "ESSD_PL0"
  validation {
    condition     = contains(["ESSD_PL0", "ESSD_FlexPL"], var.system_volume_type)
    error_message = "Use ESSD_PL0 or ESSD_FlexPL."
  }
}

variable "fixed_replicas_by_zone" {
  description = "Fixed nodes per AZ, with no autoscaling. Keys must exactly match zones; each AZ needs at least one node."
  type        = map(number)
  nullable    = false
  default = {
    cn-beijing-a = 1
    cn-beijing-c = 1
  }
  validation {
    condition = try(
      length(var.fixed_replicas_by_zone) > 0 &&
      alltrue([
        for zone, replicas in var.fixed_replicas_by_zone :
        length(trimspace(zone)) > 0 && replicas >= 1 && replicas <= 2000 && floor(replicas) == replicas
      ]),
      false
    )
    error_message = "Set a non-empty AZ map with integer fixed counts from 1 to 2000 for every selected AZ."
  }
}

variable "elastic_initial_replicas" {
  description = "Initial elastic node count. Later desired counts are owned by the autoscaler."
  type        = number
  default     = 1
}

variable "elastic_min_replicas" {
  description = "Minimum elastic node count."
  type        = number
  default     = 0
}

variable "elastic_max_replicas" {
  description = "Maximum elastic node count; align with ECS quota, subnet IP capacity and budget."
  type        = number
  default     = 10
}

variable "addon_versions" {
  description = "Explicit versions of all enabled independently deletable addons. Preflight checks Kubernetes compatibility."
  type        = map(string)
  default     = {}
  validation {
    condition = alltrue([
      for k, v in var.addon_versions :
      contains(["prometheus-agent", "log-collector", "node-problem-detector", "cluster-autoscaler"], k) && length(trimspace(v)) > 0
    ])
    error_message = "Use supported addon names and non-empty queried versions."
  }
}

variable "required_addons" {
  description = "Cluster-owned Required addons reconciled by the bundled Python script and removed only with the VKE cluster."
  type = map(object({
    version          = string
    deploy_mode      = string
    deploy_node_type = optional(string)
  }))
  default = {
    core-dns = {
      version          = "1.12.4"
      deploy_mode      = "Unmanaged"
      deploy_node_type = "Node"
    }
    metrics-server = {
      version          = "v0.7.1-vke.6"
      deploy_mode      = "Unmanaged"
      deploy_node_type = "Node"
    }
  }
  validation {
    condition = (
      toset(keys(var.required_addons)) == toset(["core-dns", "metrics-server"]) &&
      alltrue([
        for name, addon in var.required_addons :
        length(trimspace(addon.version)) > 0 &&
        contains(["Managed", "Unmanaged"], addon.deploy_mode) &&
        (
          addon.deploy_mode == "Managed" ? addon.deploy_node_type == null :
          contains(["Node", "VirtualNode"], addon.deploy_node_type == null ? "" : addon.deploy_node_type)
        )
      ])
    )
    error_message = "Define exactly core-dns and metrics-server with valid versions and deployment settings."
  }
}

variable "required_addons_reconcile_nonce" {
  description = "Change this value to rerun required-addon reconciliation after repairing external drift."
  type        = string
  default     = "run-1"
  validation {
    condition     = length(trimspace(var.required_addons_reconcile_nonce)) > 0
    error_message = "required_addons_reconcile_nonce must not be empty."
  }
}

variable "required_addons_timeout_seconds" {
  description = "Overall timeout for required-addon reconciliation."
  type        = number
  default     = 1200
  validation {
    condition     = var.required_addons_timeout_seconds >= 300 && var.required_addons_timeout_seconds <= 3600 && floor(var.required_addons_timeout_seconds) == var.required_addons_timeout_seconds
    error_message = "Use an integer from 300 to 3600 seconds."
  }
}

variable "manage_cluster_autoscaler" {
  description = "Manage cluster-autoscaler and its scale-down configuration. Import an already installed system addon first."
  type        = bool
  default     = true
}

variable "scale_down_unneeded_minutes" {
  description = "Minutes before underutilized elastic nodes can be removed."
  type        = number
  default     = 10
  validation {
    condition     = var.scale_down_unneeded_minutes >= 1 && var.scale_down_unneeded_minutes <= 60 && floor(var.scale_down_unneeded_minutes) == var.scale_down_unneeded_minutes
    error_message = "Use an integer from 1 to 60 minutes."
  }
}
