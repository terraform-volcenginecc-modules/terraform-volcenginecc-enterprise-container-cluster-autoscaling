# ==================== 平台必填参数（无默认值） ====================
region      = "cn-beijing"
name_prefix = "vke"
# 【必填】北京地域创建页中，1.32 对应的完整版本为 v1.32.3-vke.19。
# verified_at_utc 必须是实际核对时间，且部署时不能超过 24 小时。
kubernetes_version_confirmation = {
  region           = "cn-beijing"
  version          = "1.32"
  resolved_version = "v1.32.3-vke.19"
  verified_at_utc  = "2026-11-17T03:28:01.371062+00:00"
}
zones = [
  { zone_id = "cn-beijing-a", node_cidr = "10.0.0.0/24", pod_cidr = "10.0.16.0/20" },
  { zone_id = "cn-beijing-c", node_cidr = "10.0.1.0/24", pod_cidr = "10.0.32.0/20" },
]
instance_types = ["ecs.g4i.4xlarge"]

# 【必填】节点登录方式；密码模式和密钥模式二选一。
node_login_method = "Password"
# 【条件必填】密码模式填写 node_password，ssh_key_pair_name 必须为 null。
ssh_key_pair_name = null
node_password     = "REPLACE_ME"

fixed_replicas_by_zone = {
  cn-beijing-a = 1
  cn-beijing-c = 1
}

# 【必填】所有启用的独立 Addon 必须显式指定版本。
addon_versions = {
  prometheus-agent      = "v3.10.0-vke.1.30"
  log-collector         = "v2.3.3"
  node-problem-detector = "v1.36.4-vke.1"
  cluster-autoscaler    = "v1.30.3-vke.15"
}

# 【必填】CoreDNS 和 metrics-server 的明确版本及部署方式。
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

# ==================== 可选参数（已有默认值） ====================
project_name                     = "default"
vpc_cidr                         = "10.0.0.0/16"
service_cidr                     = "172.22.0.0/22"
image_id                         = null
elastic_initial_replicas         = 1
elastic_min_replicas             = 0
elastic_max_replicas             = 10
egress_bandwidth                 = 10
alb_bandwidth                    = 10
vke_delete_protection_enabled    = true
alb_delete_protection_enabled    = false
api_server_public_access_enabled = false
manage_cluster_autoscaler        = true
