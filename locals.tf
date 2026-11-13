locals {
  common_tags = merge(var.tags, {
    Name        = var.name_prefix
    Environment = var.environment
    Project     = var.project_name
    Owner       = var.owner
    CostCenter  = var.cost_center
  })

  # Integer IPv4 intervals make containment and overlap checks independent of mask size.
  cidrs = concat([var.vpc_cidr, var.service_cidr], flatten([
    for z in var.zones : [z.node_cidr, z.pod_cidr]
  ]))
  cidr_ranges = [
    for cidr in local.cidrs : {
      first = sum([for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)])
      last  = sum([for i, octet in split(".", cidrhost(cidr, -1)) : tonumber(octet) * pow(256, 3 - i)])
    }
  ]
  subnet_ranges = slice(local.cidr_ranges, 2, length(local.cidr_ranges))
  network_valid = (
    alltrue([for z in var.zones : startswith(z.zone_id, "${var.region}-")]) &&
    alltrue([for r in local.subnet_ranges : r.first >= local.cidr_ranges[0].first && r.last <= local.cidr_ranges[0].last]) &&
    (local.cidr_ranges[0].last < local.cidr_ranges[1].first || local.cidr_ranges[1].last < local.cidr_ranges[0].first) &&
    alltrue(flatten([
      for i, a in local.subnet_ranges : [
        for j, b in local.subnet_ranges : i == j || a.last < b.first || b.last < a.first
      ]
    ])) &&
    anytrue([
      for r in [
        { first = 167772160, last = 184549375 },
        { first = 2886729728, last = 2887778303 },
        { first = 3232235520, last = 3232301055 }
      ] : local.cidr_ranges[0].first >= r.first && local.cidr_ranges[0].last <= r.last
    ])
  )
}
