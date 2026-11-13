variable "name" {
  description = "Public ALB name."
  type        = string
}
variable "project_name" {
  description = "Existing project."
  type        = string
}
variable "vpc_id" {
  description = "New cluster VPC ID."
  type        = string
}
variable "zone_mappings" {
  description = "Target AZ and Node subnet mappings."
  type        = list(object({ zone_id = string, subnet_id = string }))
}
variable "bandwidth" {
  description = "Traffic-billed public EIP Mbps limit."
  type        = number
}
variable "delete_protection_enabled" {
  description = "Protect ALB deletion."
  type        = bool
}
variable "tags" {
  description = "Common ALB tags."
  type        = map(string)
}
