variable "name_prefix" {
  description = "Resource name prefix."
  type        = string
}
variable "project_name" {
  description = "Existing project."
  type        = string
}
variable "vpc_cidr" {
  description = "New VPC CIDR."
  type        = string
}
variable "zones" {
  description = "AZs and Node/Pod subnet CIDRs."
  type        = list(object({ zone_id = string, node_cidr = string, pod_cidr = string }))
}
variable "nat_spec" {
  description = "Public NAT specification."
  type        = string
}
variable "egress_bandwidth" {
  description = "Per-EIP traffic-billed bandwidth cap."
  type        = number
}
variable "tags" {
  description = "Common resource tags."
  type        = map(string)
}
variable "network_valid" {
  description = "Root validation of region ownership, private VPC, CIDR containment and non-overlap."
  type        = bool
}
