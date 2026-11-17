variable "cluster_id" {
  description = "Ready VKE cluster."
  type        = string
}
variable "name_prefix" {
  description = "Node pool name prefix."
  type        = string
}
variable "project_name" {
  description = "Project for worker ECS instances."
  type        = string
}
variable "node_subnet_ids_by_zone" {
  description = "Distinct Node subnet IDs keyed by the selected AZs."
  type        = map(string)
  nullable    = false
  validation {
    condition = try(
      length(var.node_subnet_ids_by_zone) >= 2 &&
      length(var.node_subnet_ids_by_zone) <= 3 &&
      length(distinct(values(var.node_subnet_ids_by_zone))) == length(var.node_subnet_ids_by_zone) &&
      alltrue([for zone, subnet in var.node_subnet_ids_by_zone : length(trimspace(zone)) > 0 && length(trimspace(subnet)) > 0]),
      false
    )
    error_message = "Supply one distinct Node subnet for each of 2-3 selected AZs."
  }
}
variable "instance_types" {
  description = "Supported worker ECS types."
  type        = list(string)
}
variable "image_id" {
  description = "Compatible image or null for a single type."
  type        = string
}
variable "node_login_method" {
  description = "【必填】所有节点池共用的 Worker 登录方式：SshKeyPair 或 Password。"
  type        = string
  nullable    = false
  validation {
    condition     = contains(["SshKeyPair", "Password"], var.node_login_method)
    error_message = "node_login_method must be SshKeyPair or Password."
  }
}
variable "ssh_key_pair_name" {
  description = "【条件必填】SshKeyPair 模式填写目标地域已有密钥对名称；Password 模式填 null。"
  type        = string
  default     = null
  validation {
    condition     = var.ssh_key_pair_name == null ? true : try(length(trimspace(var.ssh_key_pair_name)) > 0, false)
    error_message = "ssh_key_pair_name must be null or a non-empty regional key-pair name."
  }
}
variable "node_password" {
  description = "【条件必填、敏感】Password 模式填写原始系统密码，模板会为 VKE 自动进行 Base64 编码；SshKeyPair 模式填 null。"
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
  description = "Worker system disk GiB."
  type        = number
}
variable "system_volume_type" {
  description = "Compatible disk type."
  type        = string
}
variable "fixed_replicas_by_zone" {
  description = "Fixed node count per AZ; keys must match node_subnet_ids_by_zone."
  type        = map(number)
  nullable    = false
  validation {
    condition = try(
      length(var.fixed_replicas_by_zone) > 0 &&
      alltrue([for replicas in values(var.fixed_replicas_by_zone) : replicas >= 1 && replicas <= 2000 && floor(replicas) == replicas]),
      false
    )
    error_message = "Every fixed pool must have an integer node count from 1 to 2000."
  }
}
variable "elastic_initial_replicas" {
  description = "Initial elastic count."
  type        = number
}
variable "elastic_min_replicas" {
  description = "Elastic lower limit."
  type        = number
}
variable "elastic_max_replicas" {
  description = "Elastic upper limit."
  type        = number
}
variable "tags" {
  description = "Tags for node pools and ECS nodes."
  type        = map(string)
}
