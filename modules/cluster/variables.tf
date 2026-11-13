variable "name" {
  description = "VKE cluster name."
  type        = string
}
variable "project_name" {
  description = "Existing project."
  type        = string
}
variable "kubernetes_version" {
  description = "Target-region supported Kubernetes x.xx version."
  type        = string
}
variable "node_subnet_ids" {
  description = "Control plane and Node subnet IDs."
  type        = list(string)
}
variable "pod_subnet_ids" {
  description = "VPC-CNI Pod subnet IDs."
  type        = list(string)
}
variable "service_cidr" {
  description = "Independent Service IPv4 CIDR."
  type        = string
}
variable "delete_protection_enabled" {
  description = "Cluster deletion protection."
  type        = bool
}
variable "api_server_public_access_enabled" {
  description = "Explicit public Kubernetes API access switch."
  type        = bool
}
variable "tags" {
  description = "Common tags."
  type        = map(string)
}
