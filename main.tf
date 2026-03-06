################################################################################
# Label
################################################################################

module "label" {
  source = "git::https://github.com/Rntinc-z/module.label?ref=1.0.1"

  prefix          = var.prefix
  environment     = var.environment
  type            = var.type
  name            = var.name
  delimiter       = var.delimiter
  attributes      = var.attributes
  tags            = var.tags
  label_order     = var.label_order
  context         = var.context
  use_custom_name = var.use_custom_name
  custom_name     = var.custom_name
  enabled         = var.enabled
}

locals {
  len_public_subnets    = max(length(var.public_subnets), length(var.public_subnet_ipv6_prefixes))
  len_private_subnets   = max(length(var.private_subnets), length(var.private_subnet_ipv6_prefixes))
  len_protected_subnets = max(length(var.protected_subnets), length(var.protected_subnet_ipv6_prefixes))

  max_subnet_length = max(
    local.len_private_subnets,
    local.len_public_subnets,
  )

  # Use `local.vpc_id` to give a hint to Terraform that subnets should be deleted before secondary CIDR blocks can be free!
  vpc_id = try(aws_vpc_ipv4_cidr_block_association.this[0].vpc_id, aws_vpc.this[0].id, "")

  create_vpc = var.create_vpc && var.putin_khuylo
}

################################################################################
# VPC
################################################################################

resource "aws_vpc" "this" {
  count = local.create_vpc ? 1 : 0

  region = var.region

  cidr_block          = var.use_ipam_pool ? null : var.cidr
  ipv4_ipam_pool_id   = var.use_ipam_pool ? var.ipv4_ipam_pool_id : null
  ipv4_netmask_length = var.use_ipam_pool ? var.ipv4_netmask_length : null

  assign_generated_ipv6_cidr_block     = var.enable_ipv6 && !var.use_ipam_pool ? true : null
  ipv6_cidr_block                      = var.use_ipam_pool || var.ipv6_ipam_pool_id != null ? var.ipv6_cidr : null
  ipv6_ipam_pool_id                    = var.ipv6_ipam_pool_id
  ipv6_netmask_length                  = var.ipv6_ipam_pool_id != null ? var.ipv6_netmask_length : null
  ipv6_cidr_block_network_border_group = var.enable_ipv6 && !var.use_ipam_pool ? var.ipv6_cidr_block_network_border_group : null

  instance_tenancy                     = var.instance_tenancy
  enable_dns_hostnames                 = var.enable_dns_hostnames
  enable_dns_support                   = var.enable_dns_support
  enable_network_address_usage_metrics = var.enable_network_address_usage_metrics

  tags = merge(
    { "Name" = module.label.id },
    module.label.tags,
    var.vpc_tags,
  )
}

resource "aws_vpc_ipv4_cidr_block_association" "this" {
  count = local.create_vpc && length(var.secondary_cidr_blocks) > 0 ? length(var.secondary_cidr_blocks) : 0

  region = var.region

  # Do not turn this into `local.vpc_id`
  vpc_id = aws_vpc.this[0].id

  cidr_block = element(var.secondary_cidr_blocks, count.index)
}

resource "aws_vpc_block_public_access_options" "this" {
  count = local.create_vpc && length(keys(var.vpc_block_public_access_options)) > 0 ? 1 : 0

  region = var.region

  internet_gateway_block_mode = try(var.vpc_block_public_access_options["internet_gateway_block_mode"], null)
}

resource "aws_vpc_block_public_access_exclusion" "this" {
  for_each = { for k, v in var.vpc_block_public_access_exclusions : k => v if local.create_vpc }

  region = var.region

  vpc_id = try(each.value.exclude_vpc, false) ? local.vpc_id : null

  subnet_id = try(each.value.exclude_subnet, false) ? lookup(
    {
      private   = aws_subnet.private[*].id,
      public    = aws_subnet.public[*].id,
      protected = aws_subnet.protected[*].id
    },
    each.value.subnet_type,
    null
  )[each.value.subnet_index] : null

  internet_gateway_exclusion_mode = each.value.internet_gateway_exclusion_mode

  tags = merge(
    module.label.tags,
    try(each.value.tags, {}),
  )
}

################################################################################
# DHCP Options Set
################################################################################

resource "aws_vpc_dhcp_options" "this" {
  count = local.create_vpc && var.enable_dhcp_options ? 1 : 0

  region = var.region

  domain_name                       = var.dhcp_options_domain_name
  domain_name_servers               = var.dhcp_options_domain_name_servers
  ntp_servers                       = var.dhcp_options_ntp_servers
  netbios_name_servers              = var.dhcp_options_netbios_name_servers
  netbios_node_type                 = var.dhcp_options_netbios_node_type
  ipv6_address_preferred_lease_time = var.dhcp_options_ipv6_address_preferred_lease_time

  tags = merge(
    { "Name" = module.label.id },
    module.label.tags,
    var.dhcp_options_tags,
  )
}

resource "aws_vpc_dhcp_options_association" "this" {
  count = local.create_vpc && var.enable_dhcp_options ? 1 : 0

  region = var.region

  vpc_id          = local.vpc_id
  dhcp_options_id = aws_vpc_dhcp_options.this[0].id
}

################################################################################
# Public Subnets
################################################################################

locals {
  create_public_subnets = local.create_vpc && local.len_public_subnets > 0

  # When using default route table for public subnets, don't create separate public route tables
  num_public_route_tables = var.use_default_route_table_for_public ? 0 : (var.create_multiple_public_route_tables ? local.len_public_subnets : 1)
}

resource "aws_subnet" "public" {
  count = local.create_public_subnets && (!var.one_nat_gateway_per_az || local.len_public_subnets >= length(var.azs)) ? local.len_public_subnets : 0

  region = var.region

  assign_ipv6_address_on_creation                = var.enable_ipv6 && var.public_subnet_ipv6_native ? true : var.public_subnet_assign_ipv6_address_on_creation
  availability_zone                              = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id                           = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
  cidr_block                                     = var.public_subnet_ipv6_native ? null : element(concat(var.public_subnets, [""]), count.index)
  enable_dns64                                   = var.enable_ipv6 && var.public_subnet_enable_dns64
  enable_resource_name_dns_aaaa_record_on_launch = var.enable_ipv6 && var.public_subnet_enable_resource_name_dns_aaaa_record_on_launch
  enable_resource_name_dns_a_record_on_launch    = !var.public_subnet_ipv6_native && var.public_subnet_enable_resource_name_dns_a_record_on_launch
  ipv6_cidr_block                                = var.enable_ipv6 && length(var.public_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.public_subnet_ipv6_prefixes[count.index]) : null
  ipv6_native                                    = var.enable_ipv6 && var.public_subnet_ipv6_native
  map_public_ip_on_launch                        = var.map_public_ip_on_launch
  private_dns_hostname_type_on_launch            = var.public_subnet_private_dns_hostname_type_on_launch
  vpc_id                                         = local.vpc_id

  tags = merge(
    {
      Name = try(
        var.public_subnet_names[count.index],
        format("${module.label.id}-${var.public_subnet_suffix}-%s", element(var.azs, count.index))
      )
    },
    module.label.tags,
    var.public_subnet_tags,
    lookup(var.public_subnet_tags_per_az, element(var.azs, count.index), {})
  )
}

resource "aws_route_table" "public" {
  # Don't create public route tables when using default route table
  count = local.create_public_subnets && !var.use_default_route_table_for_public ? local.num_public_route_tables : 0

  region = var.region

  vpc_id = local.vpc_id

  tags = merge(
    {
      "Name" = var.create_multiple_public_route_tables ? format(
        "${module.label.id}-${var.public_subnet_suffix}-%s",
        element(var.azs, count.index),
      ) : "${module.label.id}-${var.public_subnet_suffix}"
    },
    module.label.tags,
    var.public_route_table_tags,
  )
}

resource "aws_route_table_association" "public" {
  # Don't create associations when using default route table (subnets use default RT automatically)
  count = local.create_public_subnets && !var.use_default_route_table_for_public ? local.len_public_subnets : 0

  region = var.region

  subnet_id      = element(aws_subnet.public[*].id, count.index)
  route_table_id = element(aws_route_table.public[*].id, var.create_multiple_public_route_tables ? count.index : 0)
}

resource "aws_route" "public_internet_gateway" {
  # Don't create route when using default route table (route should be on default RT)
  count = local.create_public_subnets && var.create_igw && !var.use_default_route_table_for_public ? local.num_public_route_tables : 0

  region = var.region

  route_table_id         = aws_route_table.public[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id

  timeouts {
    create = "5m"
  }
}

resource "aws_route" "public_internet_gateway_ipv6" {
  # Don't create route when using default route table
  count = local.create_public_subnets && var.create_igw && var.enable_ipv6 && !var.use_default_route_table_for_public ? local.num_public_route_tables : 0

  region = var.region

  route_table_id              = aws_route_table.public[count.index].id
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = aws_internet_gateway.this[0].id
}

################################################################################
# Public Network ACLs
################################################################################

resource "aws_network_acl" "public" {
  count = local.create_public_subnets && var.public_dedicated_network_acl ? 1 : 0

  region = var.region

  vpc_id     = local.vpc_id
  subnet_ids = aws_subnet.public[*].id

  tags = merge(
    { "Name" = "${module.label.id}-${var.public_subnet_suffix}" },
    module.label.tags,
    var.public_acl_tags,
  )
}

resource "aws_network_acl_rule" "public_inbound" {
  count = local.create_public_subnets && var.public_dedicated_network_acl ? length(var.public_inbound_acl_rules) : 0

  region = var.region

  network_acl_id = aws_network_acl.public[0].id

  egress          = false
  rule_number     = var.public_inbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.public_inbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.public_inbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.public_inbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.public_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.public_inbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.public_inbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.public_inbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.public_inbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

resource "aws_network_acl_rule" "public_outbound" {
  count = local.create_public_subnets && var.public_dedicated_network_acl ? length(var.public_outbound_acl_rules) : 0

  region = var.region

  network_acl_id = aws_network_acl.public[0].id

  egress          = true
  rule_number     = var.public_outbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.public_outbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.public_outbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.public_outbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.public_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.public_outbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.public_outbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.public_outbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.public_outbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

################################################################################
# Private Subnets
################################################################################

locals {
  create_private_subnets = local.create_vpc && local.len_private_subnets > 0
}

resource "aws_subnet" "private" {
  count = local.create_private_subnets ? local.len_private_subnets : 0

  region = var.region

  assign_ipv6_address_on_creation                = var.enable_ipv6 && var.private_subnet_ipv6_native ? true : var.private_subnet_assign_ipv6_address_on_creation
  availability_zone                              = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id                           = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
  cidr_block                                     = var.private_subnet_ipv6_native ? null : element(concat(var.private_subnets, [""]), count.index)
  enable_dns64                                   = var.enable_ipv6 && var.private_subnet_enable_dns64
  enable_resource_name_dns_aaaa_record_on_launch = var.enable_ipv6 && var.private_subnet_enable_resource_name_dns_aaaa_record_on_launch
  enable_resource_name_dns_a_record_on_launch    = !var.private_subnet_ipv6_native && var.private_subnet_enable_resource_name_dns_a_record_on_launch
  ipv6_cidr_block                                = var.enable_ipv6 && length(var.private_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.private_subnet_ipv6_prefixes[count.index]) : null
  ipv6_native                                    = var.enable_ipv6 && var.private_subnet_ipv6_native
  private_dns_hostname_type_on_launch            = var.private_subnet_private_dns_hostname_type_on_launch
  vpc_id                                         = local.vpc_id

  tags = merge(
    {
      Name = try(
        var.private_subnet_names[count.index],
        format("${module.label.id}-${var.private_subnet_suffix}-%s", element(var.azs, count.index))
      )
    },
    module.label.tags,
    var.private_subnet_tags,
    lookup(var.private_subnet_tags_per_az, element(var.azs, count.index), {})
  )
}

# There are as many routing tables as the number of NAT gateways
resource "aws_route_table" "private" {
  count = local.create_private_subnets && local.max_subnet_length > 0 ? local.nat_gateway_count : 0

  region = var.region

  vpc_id = local.vpc_id

  tags = merge(
    {
      "Name" = var.single_nat_gateway ? "${module.label.id}-${var.private_subnet_suffix}" : format(
        "${module.label.id}-${var.private_subnet_suffix}-%s",
        element(var.azs, count.index),
      )
    },
    module.label.tags,
    var.private_route_table_tags,
  )
}

resource "aws_route_table_association" "private" {
  count = local.create_private_subnets ? local.len_private_subnets : 0

  region = var.region

  subnet_id = element(aws_subnet.private[*].id, count.index)
  route_table_id = element(
    aws_route_table.private[*].id,
    var.single_nat_gateway ? 0 : count.index,
  )
}

################################################################################
# Private Network ACLs
################################################################################

locals {
  create_private_network_acl = local.create_private_subnets && var.private_dedicated_network_acl
}

resource "aws_network_acl" "private" {
  count = local.create_private_network_acl ? 1 : 0

  region = var.region

  vpc_id     = local.vpc_id
  subnet_ids = aws_subnet.private[*].id

  tags = merge(
    { "Name" = "${module.label.id}-${var.private_subnet_suffix}" },
    module.label.tags,
    var.private_acl_tags,
  )
}

resource "aws_network_acl_rule" "private_inbound" {
  count = local.create_private_network_acl ? length(var.private_inbound_acl_rules) : 0

  region = var.region

  network_acl_id = aws_network_acl.private[0].id

  egress          = false
  rule_number     = var.private_inbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.private_inbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.private_inbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.private_inbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.private_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.private_inbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.private_inbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.private_inbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.private_inbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

resource "aws_network_acl_rule" "private_outbound" {
  count = local.create_private_network_acl ? length(var.private_outbound_acl_rules) : 0

  region = var.region

  network_acl_id = aws_network_acl.private[0].id

  egress          = true
  rule_number     = var.private_outbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.private_outbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.private_outbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.private_outbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.private_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.private_outbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.private_outbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.private_outbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.private_outbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

################################################################################
# Protected Subnets (no external access)
################################################################################

locals {
  create_protected_subnets   = local.create_vpc && local.len_protected_subnets > 0
  num_protected_route_tables = var.create_multiple_protected_route_tables ? local.len_protected_subnets : 1
}

resource "aws_subnet" "protected" {
  count = local.create_protected_subnets ? local.len_protected_subnets : 0

  region = var.region

  assign_ipv6_address_on_creation                = var.enable_ipv6 && var.protected_subnet_ipv6_native ? true : var.protected_subnet_assign_ipv6_address_on_creation
  availability_zone                              = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id                           = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
  cidr_block                                     = var.protected_subnet_ipv6_native ? null : element(concat(var.protected_subnets, [""]), count.index)
  enable_dns64                                   = var.enable_ipv6 && var.protected_subnet_enable_dns64
  enable_resource_name_dns_aaaa_record_on_launch = var.enable_ipv6 && var.protected_subnet_enable_resource_name_dns_aaaa_record_on_launch
  enable_resource_name_dns_a_record_on_launch    = !var.protected_subnet_ipv6_native && var.protected_subnet_enable_resource_name_dns_a_record_on_launch
  ipv6_cidr_block                                = var.enable_ipv6 && length(var.protected_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.protected_subnet_ipv6_prefixes[count.index]) : null
  ipv6_native                                    = var.enable_ipv6 && var.protected_subnet_ipv6_native
  private_dns_hostname_type_on_launch            = var.protected_subnet_private_dns_hostname_type_on_launch
  vpc_id                                         = local.vpc_id

  tags = merge(
    {
      Name = try(
        var.protected_subnet_names[count.index],
        format("${module.label.id}-${var.protected_subnet_suffix}-%s", element(var.azs, count.index))
      )
    },
    module.label.tags,
    var.protected_subnet_tags,
  )
}

resource "aws_route_table" "protected" {
  count = local.create_protected_subnets ? local.num_protected_route_tables : 0

  region = var.region

  vpc_id = local.vpc_id

  tags = merge(
    {
      "Name" = var.create_multiple_protected_route_tables ? format(
        "${module.label.id}-${var.protected_subnet_suffix}-%s",
        element(var.azs, count.index),
      ) : "${module.label.id}-${var.protected_subnet_suffix}"
    },
    module.label.tags,
    var.protected_route_table_tags,
  )
}

resource "aws_route_table_association" "protected" {
  count = local.create_protected_subnets ? local.len_protected_subnets : 0

  region = var.region

  subnet_id      = element(aws_subnet.protected[*].id, count.index)
  route_table_id = element(aws_route_table.protected[*].id, var.create_multiple_protected_route_tables ? count.index : 0)
}

################################################################################
# Protected Network ACLs
################################################################################

locals {
  create_protected_network_acl = local.create_protected_subnets && var.protected_dedicated_network_acl
}

resource "aws_network_acl" "protected" {
  count = local.create_protected_network_acl ? 1 : 0

  region = var.region

  vpc_id     = local.vpc_id
  subnet_ids = aws_subnet.protected[*].id

  tags = merge(
    { "Name" = "${module.label.id}-${var.protected_subnet_suffix}" },
    module.label.tags,
    var.protected_acl_tags,
  )
}

resource "aws_network_acl_rule" "protected_inbound" {
  count = local.create_protected_network_acl ? length(var.protected_inbound_acl_rules) : 0

  region = var.region

  network_acl_id = aws_network_acl.protected[0].id

  egress          = false
  rule_number     = var.protected_inbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.protected_inbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.protected_inbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.protected_inbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.protected_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.protected_inbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.protected_inbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.protected_inbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.protected_inbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

resource "aws_network_acl_rule" "protected_outbound" {
  count = local.create_protected_network_acl ? length(var.protected_outbound_acl_rules) : 0

  region = var.region

  network_acl_id = aws_network_acl.protected[0].id

  egress          = true
  rule_number     = var.protected_outbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.protected_outbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.protected_outbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.protected_outbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.protected_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.protected_outbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.protected_outbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.protected_outbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.protected_outbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

################################################################################
# Internet Gateway
################################################################################

resource "aws_internet_gateway" "this" {
  count = local.create_public_subnets && var.create_igw ? 1 : 0

  region = var.region

  vpc_id = local.vpc_id

  tags = merge(
    { "Name" = module.label.id },
    module.label.tags,
    var.igw_tags,
  )
}

resource "aws_egress_only_internet_gateway" "this" {
  count = local.create_vpc && var.create_egress_only_igw && var.enable_ipv6 && local.max_subnet_length > 0 ? 1 : 0

  region = var.region

  vpc_id = local.vpc_id

  tags = merge(
    { "Name" = module.label.id },
    module.label.tags,
    var.igw_tags,
  )
}

resource "aws_route" "private_ipv6_egress" {
  count = local.create_vpc && var.create_egress_only_igw && var.enable_ipv6 && local.len_private_subnets > 0 ? local.nat_gateway_count : 0

  region = var.region

  route_table_id              = element(aws_route_table.private[*].id, count.index)
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = element(aws_egress_only_internet_gateway.this[*].id, 0)
}

################################################################################
# NAT Gateway
################################################################################

locals {
  nat_gateway_count = var.single_nat_gateway ? 1 : var.one_nat_gateway_per_az ? length(var.azs) : local.max_subnet_length
  nat_gateway_ips   = var.reuse_nat_ips ? var.external_nat_ip_ids : aws_eip.nat[*].id
}

resource "aws_eip" "nat" {
  count = local.create_vpc && var.enable_nat_gateway && !var.reuse_nat_ips ? local.nat_gateway_count : 0

  region = var.region

  domain = "vpc"

  tags = merge(
    {
      "Name" = format(
        "${module.label.id}-%s",
        element(var.azs, var.single_nat_gateway ? 0 : count.index),
      )
    },
    module.label.tags,
    var.nat_eip_tags,
  )

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.create_vpc && var.enable_nat_gateway ? local.nat_gateway_count : 0

  region = var.region

  allocation_id = element(
    local.nat_gateway_ips,
    var.single_nat_gateway ? 0 : count.index,
  )
  subnet_id = element(
    aws_subnet.public[*].id,
    var.single_nat_gateway ? 0 : count.index,
  )

  tags = merge(
    {
      "Name" = format(
        "${module.label.id}-%s",
        element(var.azs, var.single_nat_gateway ? 0 : count.index),
      )
    },
    module.label.tags,
    var.nat_gateway_tags,
  )

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_nat_gateway" {
  count = local.create_vpc && var.enable_nat_gateway && var.create_private_nat_gateway_route ? local.nat_gateway_count : 0

  region = var.region

  route_table_id         = element(aws_route_table.private[*].id, count.index)
  destination_cidr_block = var.nat_gateway_destination_cidr_block
  nat_gateway_id         = element(aws_nat_gateway.this[*].id, count.index)

  timeouts {
    create = "5m"
  }
}

resource "aws_route" "private_dns64_nat_gateway" {
  count = local.create_vpc && var.enable_nat_gateway && var.enable_ipv6 && var.private_subnet_enable_dns64 ? local.nat_gateway_count : 0

  region = var.region

  route_table_id              = element(aws_route_table.private[*].id, count.index)
  destination_ipv6_cidr_block = "64:ff9b::/96"
  nat_gateway_id              = element(aws_nat_gateway.this[*].id, count.index)

  timeouts {
    create = "5m"
  }
}

################################################################################
# Customer Gateways
################################################################################

resource "aws_customer_gateway" "this" {
  for_each = var.customer_gateways

  region = var.region

  bgp_asn          = lookup(each.value, "bgp_asn", null)
  bgp_asn_extended = lookup(each.value, "bgp_asn_extended", null)
  ip_address       = each.value["ip_address"]
  device_name      = lookup(each.value, "device_name", null)
  type             = "ipsec.1"

  tags = merge(
    { Name = "${module.label.id}-${each.key}" },
    module.label.tags,
    var.customer_gateway_tags,
  )

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# VPN Gateway
################################################################################

resource "aws_vpn_gateway" "this" {
  count = local.create_vpc && var.enable_vpn_gateway ? 1 : 0

  region = var.region

  vpc_id            = local.vpc_id
  amazon_side_asn   = var.amazon_side_asn
  availability_zone = var.vpn_gateway_az

  tags = merge(
    { "Name" = module.label.id },
    module.label.tags,
    var.vpn_gateway_tags,
  )
}

resource "aws_vpn_gateway_attachment" "this" {
  count = var.vpn_gateway_id != "" ? 1 : 0

  region = var.region

  vpc_id         = local.vpc_id
  vpn_gateway_id = var.vpn_gateway_id
}

resource "aws_vpn_gateway_route_propagation" "public" {
  count = local.create_vpc && var.propagate_public_route_tables_vgw && (var.enable_vpn_gateway || var.vpn_gateway_id != "") ? 1 : 0

  region = var.region

  route_table_id = element(aws_route_table.public[*].id, count.index)
  vpn_gateway_id = element(
    concat(
      aws_vpn_gateway.this[*].id,
      aws_vpn_gateway_attachment.this[*].vpn_gateway_id,
    ),
    count.index,
  )
}

resource "aws_vpn_gateway_route_propagation" "private" {
  count = local.create_vpc && var.propagate_private_route_tables_vgw && (var.enable_vpn_gateway || var.vpn_gateway_id != "") ? local.len_private_subnets : 0

  region = var.region

  route_table_id = element(aws_route_table.private[*].id, count.index)
  vpn_gateway_id = element(
    concat(
      aws_vpn_gateway.this[*].id,
      aws_vpn_gateway_attachment.this[*].vpn_gateway_id,
    ),
    count.index,
  )
}

resource "aws_vpn_gateway_route_propagation" "protected" {
  count = local.create_vpc && var.propagate_protected_route_tables_vgw && (var.enable_vpn_gateway || var.vpn_gateway_id != "") ? local.len_protected_subnets : 0

  region = var.region

  route_table_id = element(aws_route_table.protected[*].id, count.index)
  vpn_gateway_id = element(
    concat(
      aws_vpn_gateway.this[*].id,
      aws_vpn_gateway_attachment.this[*].vpn_gateway_id,
    ),
    count.index,
  )
}

################################################################################
# Default VPC
################################################################################

resource "aws_default_vpc" "this" {
  count = var.manage_default_vpc ? 1 : 0

  region = var.region

  enable_dns_support   = var.default_vpc_enable_dns_support
  enable_dns_hostnames = var.default_vpc_enable_dns_hostnames

  tags = merge(
    { "Name" = coalesce(var.default_vpc_name, "default") },
    module.label.tags,
    var.default_vpc_tags,
  )
}

resource "aws_default_security_group" "this" {
  count = local.create_vpc && var.manage_default_security_group ? 1 : 0

  region = var.region

  vpc_id = aws_vpc.this[0].id

  dynamic "ingress" {
    for_each = var.default_security_group_ingress
    content {
      self             = lookup(ingress.value, "self", null)
      cidr_blocks      = compact(split(",", lookup(ingress.value, "cidr_blocks", "")))
      ipv6_cidr_blocks = compact(split(",", lookup(ingress.value, "ipv6_cidr_blocks", "")))
      prefix_list_ids  = compact(split(",", lookup(ingress.value, "prefix_list_ids", "")))
      security_groups  = compact(split(",", lookup(ingress.value, "security_groups", "")))
      description      = lookup(ingress.value, "description", null)
      from_port        = lookup(ingress.value, "from_port", 0)
      to_port          = lookup(ingress.value, "to_port", 0)
      protocol         = lookup(ingress.value, "protocol", "-1")
    }
  }

  dynamic "egress" {
    for_each = var.default_security_group_egress
    content {
      self             = lookup(egress.value, "self", null)
      cidr_blocks      = compact(split(",", lookup(egress.value, "cidr_blocks", "")))
      ipv6_cidr_blocks = compact(split(",", lookup(egress.value, "ipv6_cidr_blocks", "")))
      prefix_list_ids  = compact(split(",", lookup(egress.value, "prefix_list_ids", "")))
      security_groups  = compact(split(",", lookup(egress.value, "security_groups", "")))
      description      = lookup(egress.value, "description", null)
      from_port        = lookup(egress.value, "from_port", 0)
      to_port          = lookup(egress.value, "to_port", 0)
      protocol         = lookup(egress.value, "protocol", "-1")
    }
  }

  tags = merge(
    { "Name" = coalesce(var.default_security_group_name, "${module.label.id}-default") },
    module.label.tags,
    var.default_security_group_tags,
  )
}

################################################################################
# Default Network ACLs
################################################################################

resource "aws_default_network_acl" "this" {
  count = local.create_vpc && var.manage_default_network_acl ? 1 : 0

  region = var.region

  default_network_acl_id = aws_vpc.this[0].default_network_acl_id

  # subnet_ids is using lifecycle ignore_changes, so it is not necessary to list
  # any explicitly. See https://github.com/terraform-aws-modules/terraform-aws-vpc/issues/736
  subnet_ids = null

  dynamic "ingress" {
    for_each = var.default_network_acl_ingress
    content {
      action          = ingress.value.action
      cidr_block      = lookup(ingress.value, "cidr_block", null)
      from_port       = ingress.value.from_port
      icmp_code       = lookup(ingress.value, "icmp_code", null)
      icmp_type       = lookup(ingress.value, "icmp_type", null)
      ipv6_cidr_block = lookup(ingress.value, "ipv6_cidr_block", null)
      protocol        = ingress.value.protocol
      rule_no         = ingress.value.rule_no
      to_port         = ingress.value.to_port
    }
  }
  dynamic "egress" {
    for_each = var.default_network_acl_egress
    content {
      action          = egress.value.action
      cidr_block      = lookup(egress.value, "cidr_block", null)
      from_port       = egress.value.from_port
      icmp_code       = lookup(egress.value, "icmp_code", null)
      icmp_type       = lookup(egress.value, "icmp_type", null)
      ipv6_cidr_block = lookup(egress.value, "ipv6_cidr_block", null)
      protocol        = egress.value.protocol
      rule_no         = egress.value.rule_no
      to_port         = egress.value.to_port
    }
  }

  tags = merge(
    { "Name" = coalesce(var.default_network_acl_name, module.label.id) },
    module.label.tags,
    var.default_network_acl_tags,
  )

  lifecycle {
    ignore_changes = [subnet_ids]
  }
}

################################################################################
# Default Route Table
################################################################################

resource "aws_default_route_table" "default" {
  count = local.create_vpc && var.manage_default_route_table ? 1 : 0

  region = var.region

  default_route_table_id = aws_vpc.this[0].default_route_table_id
  propagating_vgws       = var.default_route_table_propagating_vgws

  dynamic "route" {
    for_each = var.default_route_table_routes
    content {
      # One of the following destinations must be provided
      cidr_block      = route.value.cidr_block
      ipv6_cidr_block = lookup(route.value, "ipv6_cidr_block", null)

      # One of the following targets must be provided
      egress_only_gateway_id    = lookup(route.value, "egress_only_gateway_id", null)
      gateway_id                = lookup(route.value, "gateway_id", null)
      nat_gateway_id            = lookup(route.value, "nat_gateway_id", null)
      network_interface_id      = lookup(route.value, "network_interface_id", null)
      transit_gateway_id        = lookup(route.value, "transit_gateway_id", null)
      vpc_endpoint_id           = lookup(route.value, "vpc_endpoint_id", null)
      vpc_peering_connection_id = lookup(route.value, "vpc_peering_connection_id", null)
    }
  }

  timeouts {
    create = "5m"
    update = "5m"
  }

  tags = merge(
    { "Name" = coalesce(var.default_route_table_name, module.label.id) },
    module.label.tags,
    var.default_route_table_tags,
  )
}

################################################################################
# VPC Flow Log
################################################################################

locals {
  # Only create flow log if user hasn't specified an ARN
  # If create_flow_log_cloudwatch_log_group is true, we create the log group
  # If create_flow_log_cloudwatch_iam_role is true, we create the IAM role
  create_flow_log_cloudwatch_iam_role  = local.create_vpc && var.enable_flow_log && var.flow_log_destination_type != "s3" && var.create_flow_log_cloudwatch_iam_role
  create_flow_log_cloudwatch_log_group = local.create_vpc && var.enable_flow_log && var.flow_log_destination_type != "s3" && var.create_flow_log_cloudwatch_log_group
  flow_log_destination_arn             = local.create_flow_log_cloudwatch_log_group ? aws_cloudwatch_log_group.flow_log[0].arn : var.flow_log_destination_arn
  flow_log_iam_role_arn                = var.flow_log_destination_type != "s3" && local.create_flow_log_cloudwatch_iam_role ? aws_iam_role.vpc_flow_log_cloudwatch[0].arn : var.flow_log_cloudwatch_iam_role_arn
}

resource "aws_flow_log" "this" {
  count = local.create_vpc && var.enable_flow_log ? 1 : 0

  region = var.region

  log_destination_type       = var.flow_log_destination_type
  log_destination            = local.flow_log_destination_arn
  log_format                 = var.flow_log_log_format
  iam_role_arn               = local.flow_log_iam_role_arn
  deliver_cross_account_role = var.flow_log_deliver_cross_account_role
  traffic_type               = var.flow_log_traffic_type
  vpc_id                     = local.vpc_id
  max_aggregation_interval   = var.flow_log_max_aggregation_interval

  dynamic "destination_options" {
    for_each = var.flow_log_destination_type == "s3" ? [true] : []

    content {
      file_format                = var.flow_log_file_format
      hive_compatible_partitions = var.flow_log_hive_compatible_partitions
      per_hour_partition         = var.flow_log_per_hour_partition
    }
  }

  tags = merge(
    module.label.tags,
    var.vpc_flow_log_tags,
  )
}

resource "aws_cloudwatch_log_group" "flow_log" {
  count = local.create_flow_log_cloudwatch_log_group ? 1 : 0

  name              = "${var.flow_log_cloudwatch_log_group_name_prefix}${module.label.id}${var.flow_log_cloudwatch_log_group_name_suffix}"
  retention_in_days = var.flow_log_cloudwatch_log_group_retention_in_days
  kms_key_id        = var.flow_log_cloudwatch_log_group_kms_key_id
  skip_destroy      = var.flow_log_cloudwatch_log_group_skip_destroy
  log_group_class   = var.flow_log_cloudwatch_log_group_class

  tags = merge(
    module.label.tags,
    var.vpc_flow_log_tags,
  )
}

resource "aws_iam_role" "vpc_flow_log_cloudwatch" {
  count = local.create_flow_log_cloudwatch_iam_role ? 1 : 0

  name_prefix          = var.vpc_flow_log_iam_role_use_name_prefix ? "${var.vpc_flow_log_iam_role_name}-" : null
  name                 = var.vpc_flow_log_iam_role_use_name_prefix ? null : var.vpc_flow_log_iam_role_name
  path                 = var.vpc_flow_log_iam_role_path
  permissions_boundary = var.vpc_flow_log_permissions_boundary

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSVPCFlowLogsAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(
    module.label.tags,
    var.vpc_flow_log_tags,
  )
}

resource "aws_iam_role_policy" "vpc_flow_log_cloudwatch" {
  count = local.create_flow_log_cloudwatch_iam_role ? 1 : 0

  name_prefix = var.vpc_flow_log_iam_policy_use_name_prefix ? "${var.vpc_flow_log_iam_policy_name}-" : null
  name        = var.vpc_flow_log_iam_policy_use_name_prefix ? null : var.vpc_flow_log_iam_policy_name
  role        = aws_iam_role.vpc_flow_log_cloudwatch[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSVPCFlowLogsPushToCloudWatch"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "*"
      }
    ]
  })
}
