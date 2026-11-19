locals {
  zones = { for z in var.zones : z.zone_id => z }
  tags  = [for k, v in var.tags : { key = k, value = v }]
}

resource "volcenginecc_vpc_vpc" "this" {
  vpc_name     = "${var.name_prefix}-vpc"
  cidr_block   = var.vpc_cidr
  enable_ipv_6 = false
  project_name = var.project_name
  tags         = local.tags
  lifecycle {
    precondition {
      condition     = var.network_valid
      error_message = "Use AZs in the selected region and non-overlapping Node/Pod subnets inside a private VPC. The Service CIDR must not overlap the VPC."
    }
  }
}

resource "volcenginecc_vpc_subnet" "node" {
  for_each    = local.zones
  subnet_name = "${var.name_prefix}-node-${each.key}"
  cidr_block  = each.value.node_cidr
  zone_id     = each.key
  vpc_id      = volcenginecc_vpc_vpc.this.id
  tags        = local.tags
}

resource "volcenginecc_vpc_subnet" "pod" {
  for_each    = local.zones
  subnet_name = "${var.name_prefix}-pod-${each.key}"
  cidr_block  = each.value.pod_cidr
  zone_id     = each.key
  vpc_id      = volcenginecc_vpc_vpc.this.id
  tags        = local.tags
}

resource "volcenginecc_natgateway_ngw" "this" {
  nat_gateway_name = "${var.name_prefix}-nat"
  vpc_id           = volcenginecc_vpc_vpc.this.id
  subnet_id        = volcenginecc_vpc_subnet.node[var.zones[0].zone_id].id
  network_type     = "internet"
  billing_type     = 2
  spec             = var.nat_spec
  project_name     = var.project_name
  tags             = local.tags
}

# Role-based keys keep the number of outbound EIPs independent of the AZ count.
# Bind serially: concurrent association to the same NAT can conflict.
resource "volcenginecc_vpc_eip" "node" {
  name          = "${var.name_prefix}-node-egress"
  billing_type  = 3
  bandwidth     = var.egress_bandwidth
  isp           = "BGP"
  instance_id   = volcenginecc_natgateway_ngw.this.id
  instance_type = "Nat"
  project_name  = var.project_name
  tags          = local.tags
}

resource "volcenginecc_vpc_eip" "pod" {
  name          = "${var.name_prefix}-pod-egress"
  billing_type  = 3
  bandwidth     = var.egress_bandwidth
  isp           = "BGP"
  instance_id   = volcenginecc_natgateway_ngw.this.id
  instance_type = "Nat"
  project_name  = var.project_name
  tags          = local.tags
  depends_on    = [volcenginecc_vpc_eip.node]
}

# Each AZ has a Node and Pod rule. Explicit slots serialize each initial
# association and SNAT creation, even when Terraform parallelism is ten.
resource "volcenginecc_natgateway_snatentry" "node_a" {
  nat_gateway_id  = volcenginecc_natgateway_ngw.this.id
  subnet_id       = volcenginecc_vpc_subnet.node[var.zones[0].zone_id].id
  eip_id          = volcenginecc_vpc_eip.node.id
  snat_entry_name = "${var.name_prefix}-node-${var.zones[0].zone_id}"
  depends_on      = [volcenginecc_vpc_eip.pod]
}

resource "volcenginecc_natgateway_snatentry" "pod_a" {
  nat_gateway_id  = volcenginecc_natgateway_ngw.this.id
  subnet_id       = volcenginecc_vpc_subnet.pod[var.zones[0].zone_id].id
  eip_id          = volcenginecc_vpc_eip.pod.id
  snat_entry_name = "${var.name_prefix}-pod-${var.zones[0].zone_id}"
  depends_on      = [volcenginecc_natgateway_snatentry.node_a]
}

resource "volcenginecc_natgateway_snatentry" "node_b" {
  nat_gateway_id  = volcenginecc_natgateway_ngw.this.id
  subnet_id       = volcenginecc_vpc_subnet.node[var.zones[1].zone_id].id
  eip_id          = volcenginecc_vpc_eip.node.id
  snat_entry_name = "${var.name_prefix}-node-${var.zones[1].zone_id}"
  depends_on      = [volcenginecc_natgateway_snatentry.pod_a]
}

resource "volcenginecc_natgateway_snatentry" "pod_b" {
  nat_gateway_id  = volcenginecc_natgateway_ngw.this.id
  subnet_id       = volcenginecc_vpc_subnet.pod[var.zones[1].zone_id].id
  eip_id          = volcenginecc_vpc_eip.pod.id
  snat_entry_name = "${var.name_prefix}-pod-${var.zones[1].zone_id}"
  depends_on      = [volcenginecc_natgateway_snatentry.node_b]
}

resource "volcenginecc_natgateway_snatentry" "node_c" {
  count           = length(var.zones) == 3 ? 1 : 0
  nat_gateway_id  = volcenginecc_natgateway_ngw.this.id
  subnet_id       = volcenginecc_vpc_subnet.node[var.zones[2].zone_id].id
  eip_id          = volcenginecc_vpc_eip.node.id
  snat_entry_name = "${var.name_prefix}-node-${var.zones[2].zone_id}"
  depends_on      = [volcenginecc_natgateway_snatentry.pod_b]
}

resource "volcenginecc_natgateway_snatentry" "pod_c" {
  count           = length(var.zones) == 3 ? 1 : 0
  nat_gateway_id  = volcenginecc_natgateway_ngw.this.id
  subnet_id       = volcenginecc_vpc_subnet.pod[var.zones[2].zone_id].id
  eip_id          = volcenginecc_vpc_eip.pod.id
  snat_entry_name = "${var.name_prefix}-pod-${var.zones[2].zone_id}"
  depends_on      = [volcenginecc_natgateway_snatentry.node_c]
}
