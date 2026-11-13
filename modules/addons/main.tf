resource "volcenginecc_vke_addon" "prometheus" {
  cluster_id = var.cluster_id
  name       = "prometheus-agent"
  version    = lookup(var.addon_versions, "prometheus-agent", null)
}

resource "volcenginecc_vke_addon" "logging" {
  cluster_id = var.cluster_id
  name       = "log-collector"
  version    = lookup(var.addon_versions, "log-collector", null)
  depends_on = [volcenginecc_vke_addon.prometheus]
}

resource "volcenginecc_vke_addon" "npd" {
  cluster_id = var.cluster_id
  name       = "node-problem-detector"
  version    = lookup(var.addon_versions, "node-problem-detector", null)
  depends_on = [volcenginecc_vke_addon.logging]
}

data "volcenginecc_vke_addon" "alb" {
  id = "${var.cluster_id}|alb-ingress-controller"

  lifecycle {
    postcondition {
      condition = (
        self.cluster_id == var.cluster_id && self.name == "alb-ingress-controller" &&
        self.deploy_mode == "Managed" &&
        self.status.phase == "Running"
      )
      error_message = "Expected the platform addon to belong to this cluster and be Running; ALB and CCM must be Managed."
    }
  }
}

data "volcenginecc_vke_addon" "ccm" {
  id = "${var.cluster_id}|cloud-controller-manager"
  lifecycle {
    postcondition {
      condition     = self.cluster_id == var.cluster_id && self.name == "cloud-controller-manager" && self.deploy_mode == "Managed" && self.status.phase == "Running"
      error_message = "Expected the Managed CCM addon in this cluster to be Running."
    }
  }
}

data "volcenginecc_vke_addon" "vpc_cni" {
  id = "${var.cluster_id}|vpc-cni"
  lifecycle {
    postcondition {
      condition     = self.cluster_id == var.cluster_id && self.name == "vpc-cni" && self.status.phase == "Running"
      error_message = "Expected the platform VPC-CNI addon in this cluster to be Running."
    }
  }
}

locals {
  platform_addons = {
    alb-ingress-controller   = data.volcenginecc_vke_addon.alb
    cloud-controller-manager = data.volcenginecc_vke_addon.ccm
    vpc-cni                  = data.volcenginecc_vke_addon.vpc_cni
  }
}

# Some VKE versions install this as a system component. Import it before apply
# in that case, rather than attempting to create a duplicate.
resource "volcenginecc_vke_addon" "autoscaler" {
  count      = var.manage_cluster_autoscaler ? 1 : 0
  cluster_id = var.cluster_id
  name       = "cluster-autoscaler"
  version    = lookup(var.addon_versions, "cluster-autoscaler", null)
  config = jsonencode({
    ScanInterval = "15s"
    ScaleUp      = { Expander = "least-waste" }
    ScaleDown = {
      Enabled                           = true
      UtilizationThreshold              = 0.5
      GpuUtilizationThreshold           = 0.5
      UnneededTime                      = var.scale_down_unneeded_minutes
      DelayAfterAdded                   = 10
      DelayAfterFailure                 = 3
      SkipNodesWithLocalStorageDisabled = false
      SkipNodesWithSystemPodsDisabled   = false
      MaxEmptyBulkDeleteNumber          = 1
      MinReplicas                       = 0
      MaxGracefulTermination            = 600
      DaemonSetEvictionForNodesDisabled = false
    }
  })
  depends_on = [volcenginecc_vke_addon.npd, data.volcenginecc_vke_addon.alb]
}

resource "terraform_data" "required_addons" {
  triggers_replace = [
    var.cluster_id,
    var.region,
    jsonencode(var.required_addons),
    var.required_addons_nonce,
    filesha256(var.required_addons_script),
    filesha256("${dirname(var.required_addons_script)}/preflight.py"),
  ]

  provisioner "local-exec" {
    command = "python3 \"$REQUIRED_ADDONS_SCRIPT\""
    environment = {
      REQUIRED_ADDONS_CLUSTER_ID = var.cluster_id
      REQUIRED_ADDONS_JSON       = jsonencode(var.required_addons)
      REQUIRED_ADDONS_REGION     = var.region
      REQUIRED_ADDONS_SCRIPT     = var.required_addons_script
      REQUIRED_ADDONS_TIMEOUT    = tostring(var.required_addons_timeout)
    }
    interpreter = ["/bin/sh", "-c"]
  }

  depends_on = [
    volcenginecc_vke_addon.prometheus,
    volcenginecc_vke_addon.logging,
    volcenginecc_vke_addon.npd,
    volcenginecc_vke_addon.autoscaler,
    data.volcenginecc_vke_addon.alb,
    data.volcenginecc_vke_addon.ccm,
    data.volcenginecc_vke_addon.vpc_cni,
  ]
}

data "volcenginecc_vke_addon" "core_dns" {
  id = "${var.cluster_id}|core-dns"

  lifecycle {
    postcondition {
      condition = (
        self.cluster_id == var.cluster_id &&
        self.name == "core-dns" &&
        self.version == var.required_addons["core-dns"].version &&
        self.deploy_mode == var.required_addons["core-dns"].deploy_mode &&
        self.deploy_node_type == var.required_addons["core-dns"].deploy_node_type &&
        self.status.phase == "Running"
      )
      error_message = "Required addon reconciliation did not produce the requested Running component."
    }
  }

  depends_on = [terraform_data.required_addons]
}

data "volcenginecc_vke_addon" "metrics_server" {
  id = "${var.cluster_id}|metrics-server"
  lifecycle {
    postcondition {
      condition = (
        self.cluster_id == var.cluster_id && self.name == "metrics-server" &&
        self.version == var.required_addons["metrics-server"].version &&
        self.deploy_mode == var.required_addons["metrics-server"].deploy_mode &&
        self.deploy_node_type == var.required_addons["metrics-server"].deploy_node_type &&
        self.status.phase == "Running"
      )
      error_message = "Expected the requested metrics-server version and deployment settings to be Running."
    }
  }
  depends_on = [terraform_data.required_addons]
}

locals {
  required_addon_readback = {
    core-dns       = data.volcenginecc_vke_addon.core_dns
    metrics-server = data.volcenginecc_vke_addon.metrics_server
  }
}
