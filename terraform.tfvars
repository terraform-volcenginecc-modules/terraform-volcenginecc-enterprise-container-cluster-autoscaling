# Candidate configuration, not a region-availability assertion.
# Verify AZs, Kubernetes, ECS types, images and addon versions before deployment.
region             = "cn-beijing"
name_prefix        = "vke"
project_name       = "default"
vpc_cidr           = "10.0.0.0/16"
service_cidr       = "172.22.0.0/22"
kubernetes_version = "1.32"
zones = [
  { zone_id = "cn-beijing-a", node_cidr = "10.0.0.0/24", pod_cidr = "10.0.16.0/20" },
  { zone_id = "cn-beijing-c", node_cidr = "10.0.1.0/24", pod_cidr = "10.0.32.0/20" },
]
instance_types = ["ecs.g4il.4xlarge"]
image_id       = null
# Default key login: provide ssh_key_pair_name through TF_VAR_ssh_key_pair_name.
# Password mode: override node_login_method and node_password in a controlled
# variable file (these assignments take precedence over TF_VAR_*).
node_login_method = "SshKeyPair"
node_password     = null
fixed_replicas_by_zone = {
  cn-beijing-a = 1
  cn-beijing-c = 1
}
elastic_initial_replicas         = 1
elastic_min_replicas             = 0
elastic_max_replicas             = 10
egress_bandwidth                 = 10
alb_bandwidth                    = 10
vke_delete_protection_enabled    = true
alb_delete_protection_enabled    = false
api_server_public_access_enabled = false
manage_cluster_autoscaler        = true
# Supply the existing regional key-pair name via TF_VAR_ssh_key_pair_name.
# Supply a current kubernetes_version_confirmation in a controlled variable file.
# No regional creation availability is inferred from the default minor version.
# Populate addon_versions from the preflight result for reproducible deployment.
# Beijing / Kubernetes 1.32 selections queried on 2026-11-11; recheck before use.
addon_versions = {
  prometheus-agent      = "v3.10.0-vke.1.30"
  log-collector         = "v2.3.3"
  node-problem-detector = "v1.36.4-vke.1"
  cluster-autoscaler    = "v1.30.3-vke.15"
}
required_addons = {
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
