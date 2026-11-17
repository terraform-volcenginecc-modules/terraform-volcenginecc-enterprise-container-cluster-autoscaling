variable "region" {
  description = "【必填】目标火山引擎地域，必须与 zones 和 kubernetes_version_confirmation.region 一致。"
  type        = string
}

variable "name_prefix" {
  description = "【必填】资源名称前缀，同一账号和地域内应保持唯一。"
  type        = string
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
  description = "【必填】目标地域内的 2–3 个可用区，以及各区互不重叠的 Node/Pod 网段。"
  type = list(object({
    zone_id   = string
    node_cidr = string
    pod_cidr  = string
  }))
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
  description = "【必填】Kubernetes 次版本，必须与 kubernetes_version_confirmation.version 一致。"
  type        = string
  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "Use x.xx format, such as 1.32."
  }
}

variable "kubernetes_version_confirmation" {
  description = "【必填】目标地域 Kubernetes 创建版本确认。完整版本和核对时间须来自 VKE 创建集群页面，有效期 24 小时。"
  type = object({
    region           = string
    version          = string
    resolved_version = string
    verified_at_utc  = string
  })
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
  description = "【必填】1–10 个在全部所选可用区中受 VKE 支持且有库存的 ECS 规格。"
  type        = list(string)
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
  description = "【条件必填】选择多个 instance_types 时填写所有规格共同支持的镜像 ID；单规格可填 null，使用 VKE 默认镜像。"
  type        = string
  default     = null
}

variable "node_login_method" {
  description = "【必填】固定池和弹性池共用的 Worker 登录方式：SshKeyPair 或 Password。"
  type        = string
  nullable    = false
  validation {
    condition     = contains(["SshKeyPair", "Password"], var.node_login_method)
    error_message = "node_login_method must be SshKeyPair or Password."
  }
}

variable "ssh_key_pair_name" {
  description = "【条件必填】node_login_method 为 SshKeyPair 时填写目标地域已有的 ECS SSH 密钥对名称；Password 模式填 null，禁止传入私钥。"
  type        = string
  default     = null
  validation {
    condition     = var.ssh_key_pair_name == null ? true : try(length(trimspace(var.ssh_key_pair_name)) > 0, false)
    error_message = "ssh_key_pair_name must be null or a non-empty regional key-pair name."
  }
}

variable "node_password" {
  description = "【条件必填、敏感】node_login_method 为 Password 时填写 Worker 原始系统密码，模板会为 VKE 自动进行 Base64 编码；SshKeyPair 模式填 null。"
  type        = string
  default     = null
  sensitive   = true
  validation {
    condition = var.node_password == null ? true : try(
      length(var.node_password) >= 8 && length(var.node_password) <= 30 &&
      can(regex("^[A-Za-z0-9()~!@#$%^&*_+=-]+$", var.node_password)) &&
      !startswith(var.node_password, "/") && !startswith(var.node_password, "$6$") &&
      length([for pattern in ["[a-z]", "[A-Z]", "[0-9]", "[()~!@#$%^&*_+=-]"] : pattern if can(regex(pattern, var.node_password))]) >= 3,
      false
    )
    error_message = "node_password must be null or 8-30 characters using at least three of lowercase, uppercase, digits and ()~!@#$%^&*_+=-; it cannot start with / or $6$."
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
  description = "【必填】各可用区固定节点数，键必须与 zones 完全一致，每区至少 1 个节点。"
  type        = map(number)
  nullable    = false
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
  description = "【必填】所有启用且可独立卸载的 Addon 版本；预检会核对 Kubernetes 兼容性。"
  type        = map(string)
  validation {
    condition = alltrue([
      for k, v in var.addon_versions :
      contains(["prometheus-agent", "log-collector", "node-problem-detector", "cluster-autoscaler"], k) && length(trimspace(v)) > 0
    ])
    error_message = "Use supported addon names and non-empty queried versions."
  }
}

variable "required_addons" {
  description = "【必填】集群必需的 CoreDNS 和 metrics-server 版本及部署方式；预检会核对 Kubernetes 兼容性。"
  type = map(object({
    version          = string
    deploy_mode      = string
    deploy_node_type = optional(string)
  }))
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
