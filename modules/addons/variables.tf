variable "cluster_id" {
  description = "VKE cluster with ready node pools."
  type        = string
}
variable "region" {
  description = "Region used by the required-addon reconciler."
  type        = string
}
variable "addon_versions" {
  description = "Explicit component versions validated by deployment preflight."
  type        = map(string)
}
variable "required_addons" {
  description = "Cluster-owned Required addons."
  type = map(object({
    version          = string
    deploy_mode      = string
    deploy_node_type = optional(string)
  }))
}
variable "required_addons_script" {
  description = "Absolute path to the bundled required-addon reconciler."
  type        = string
}
variable "required_addons_nonce" {
  description = "Explicit reconciliation rerun token."
  type        = string
}
variable "required_addons_timeout" {
  description = "Required-addon reconciliation timeout in seconds."
  type        = number
}
variable "manage_cluster_autoscaler" {
  description = "Install/import and configure the autoscaler addon."
  type        = bool
}
variable "scale_down_unneeded_minutes" {
  description = "Scale-down underutilization delay in minutes."
  type        = number
}
