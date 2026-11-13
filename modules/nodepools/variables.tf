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
variable "ssh_key_pair_name" {
  description = "Existing regional SSH key pair."
  type        = string
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
