# CIDR layout for a /16, per AZ index i:
#   Public   cidrsubnet(cidr, 8, i)      -> /24, NAT and load balancers
#   Private  cidrsubnet(cidr, 4, 1 + i)  -> /20, workloads, starts at .16

locals {
  # Subnet CIDRs derived from the VPC's /16:
  #   public  : /24 chunks at .0, .1, .2 (one per AZ)
  #   private : /20 chunks at .16, .32, .48 (one per AZ)
  public_cidrs  = [for i, _ in var.azs : cidrsubnet(var.cidr_block, 8, i)]
  private_cidrs = [for i, _ in var.azs : cidrsubnet(var.cidr_block, 4, 1 + i)]

  # Which NAT an AZ egresses through: its own when it has one, otherwise
  # the first. That fallback is how a single instance serves a whole VPC,
  # and what lets an AZ take its own table before it has its own NAT.
  nat_for_az = {
    for az in var.azs : az => (
      contains(var.nat_instance_azs, az) ? az : try(var.nat_instance_azs[0], "")
    )
  }

  # EVERY private table, shared and per-AZ. Anything attaching to "the
  # private route table" must use this: a gateway endpoint left on the
  # shared one takes S3 away from the AZs that moved off it, as a routing
  # black hole rather than an error.
  private_route_table_ids = concat(
    [aws_route_table.private.id],
    [for az in var.per_az_route_tables : aws_route_table.private_az[az].id],
  )
}

# --- VPC -----------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block = var.cidr_block

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "Main VPC - ${var.env}"
  })
}

# --- Internet Gateway (public subnets' egress) ---------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "Main IGW - ${var.env}"
  })
}

# --- Subnets -------------------------------------------------------------

resource "aws_subnet" "public" {
  for_each = { for i, az in var.azs : az => i }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidrs[each.value]
  availability_zone       = each.key
  map_public_ip_on_launch = false # don't auto-assign; ALB/NAT GW request their own EIPs

  tags = merge(var.tags, {
    Name = "Public ${each.key}"
  })
}

resource "aws_subnet" "private" {
  for_each = { for i, az in var.azs : az => i }

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[each.value]
  availability_zone = each.key

  tags = merge(var.tags, {
    Name = "Private ${each.key}"
  })
}

# --- Route tables --------------------------------------------------------

# Routes are SEPARATE resources, never inline `route` blocks.
#
# An inline block is authoritative: Terraform treats it as the complete set
# and deletes anything it does not list. A peering route added from another
# state file would therefore survive until the next apply of THIS module
# and then vanish — silently, during an unrelated change, breaking
# cross-region replication with nothing in the diff to explain it.
#
# Separate resources make the table extensible, which is what a second
# region needs.

# Single public route table — all public subnets route to IGW.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "Public Routes"
  })
}

resource "aws_route" "public_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private route table — has a 0.0.0.0/0 → NAT route IFF NAT is enabled.
# Without NAT, private subnets reach the VPC's CIDR plus whatever the gateway
# endpoints below cover (S3, DynamoDB). That's intentional for cost-free
# "VPC only" envs.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "Private Routes"
  })
}

# ONE resource, whose TARGET switches — never two resources racing for the
# same destination. Two of them (one per nat_mode) have no dependency
# between them, so Terraform runs the create and the destroy concurrently
# and the create loses with RouteAlreadyExists, leaving the table with no
# default route at all. Seen 2026-09-08, rolling back a cutover.
#
# The instance target is the ENI, not the instance: replacing the box
# leaves the route and the egress address untouched.
resource "aws_route" "private_nat" {
  count = var.enable_nat ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"

  nat_gateway_id = var.nat_mode == "gateway" ? aws_nat_gateway.regional[0].id : null
  network_interface_id = (var.nat_mode == "instance"
    ? module.nat_instance[var.nat_instance_azs[0]].network_interface_id
  : null)
}

# Per-AZ private tables, for the AZs that have opted out of the shared one.
#
# ADDITIVE by design: the shared table is untouched, so an AZ moves off it
# one at a time and moves back by removing an entry. No state surgery, and
# no apply that reshapes every zone at once.
#
# The cost of a move is a few seconds: a subnet holds exactly one
# association, so there is no create-before-destroy, and it falls back to
# the VPC main table until the new one lands. Move AZ-c first — it holds
# Sentinel arbiters and no data, so the blip costs one vote out of three
# and quorum never breaks.
resource "aws_route_table" "private_az" {
  for_each = toset(var.per_az_route_tables)

  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "Private Routes ${each.key}"
  })
}

resource "aws_route" "private_az_nat" {
  for_each = var.enable_nat ? toset(var.per_az_route_tables) : toset([])

  route_table_id         = aws_route_table.private_az[each.key].id
  destination_cidr_block = "0.0.0.0/0"

  nat_gateway_id = var.nat_mode == "gateway" ? aws_nat_gateway.regional[0].id : null
  network_interface_id = (var.nat_mode == "instance"
    ? module.nat_instance[local.nat_for_az[each.key]].network_interface_id
  : null)
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id = each.value.id
  route_table_id = (contains(var.per_az_route_tables, each.key)
    ? aws_route_table.private_az[each.key].id
  : aws_route_table.private.id)
}

# --- Gateway VPC endpoints (S3, DynamoDB) --------------------------------
#
# Unconditional and free — route-table entries, not PrivateLink. Without
# them the capture pipeline pays NAT data processing on every captured body,
# which is the dominant cost line at volume.
#
# Private route table only, and created even when enable_nat is false: with
# no NAT they are the ONLY route to S3 and DynamoDB from a private subnet.
#
# No endpoint policy: task roles already constrain access, and a second
# place to get bucket permissions wrong is worth avoiding.

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.private_route_table_ids

  tags = merge(var.tags, {
    Name = "S3 Gateway Endpoint"
  })
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.private_route_table_ids

  tags = merge(var.tags, {
    Name = "DynamoDB Gateway Endpoint"
  })
}

# --- NAT Gateway (conditional) -------------------------------------------
#
# REGIONAL NAT in manual mode: one gateway holding addresses in
# `nat_pinned_azs` only, serving every AZ — an unpinned AZ's traffic is
# processed by a pinned AZ's address.
#
# Supplying availability_zone_address DISABLES auto-expansion permanently,
# so the egress IP set stays fixed and a customer's allow-list stays
# correct. That is the reason to pin fewer AZs than the VPC spans.

# A NEW address, not the old `aws_eip.nat` / `aws_nat_gateway.main`:
# provider 6.61 cannot plan a zonal -> regional transition on an existing
# gateway, and -replace hits the same path. Renaming makes it an ordinary
# create, so egress pauses only for the route update. Do not "tidy" these
# back to the old names.

resource "aws_eip" "regional_nat" {
  count = var.enable_nat ? length(var.nat_pinned_azs) : 0

  domain = "vpc"

  tags = merge(var.tags, {
    Name = "NAT EIP ${var.nat_pinned_azs[count.index]}"
  })

  depends_on = [aws_internet_gateway.main]
}

# Existence is `nat_pinned_azs`, NOT `nat_mode`. A gateway with nothing
# routed to it is a fallback the route can be moved back to in seconds,
# keeping its address; one destroyed on the mode flip is gone, and the
# rebuild gets a different EIP.
resource "aws_nat_gateway" "regional" {
  count = var.enable_nat && length(var.nat_pinned_azs) > 0 ? 1 : 0

  availability_mode = "regional"
  vpc_id            = aws_vpc.main.id

  # No subnet_id: a regional gateway belongs to the VPC, not a subnet.
  dynamic "availability_zone_address" {
    for_each = var.nat_pinned_azs
    content {
      availability_zone = availability_zone_address.value
      allocation_ids    = [aws_eip.regional_nat[index(var.nat_pinned_azs, availability_zone_address.value)].id]
    }
  }

  tags = merge(var.tags, {
    Name = "Main NAT - ${var.env}"
  })

  depends_on = [aws_internet_gateway.main]
}

# --- NAT instances (conditional) -----------------------------------------
#
# The other half of `nat_mode`. One instance per AZ in
# `nat_instance_azs`, each in that AZ's PUBLIC subnet, holding its own
# address.
#
# Today every private subnet routes through the first one, because there
# is a single private route table. Per-AZ egress needs a table per AZ —
# and the S3/DynamoDB gateway endpoints re-pointed at all of them, or the
# AZs that lose the shared table lose their free path to S3 as a routing
# black hole rather than an error.


# Both invariants fail as something confusing without this: an empty list
# silently leaves the private table with no default route, and an AZ with
# no public subnet errors deep inside the module on a missing map key.
resource "terraform_data" "nat_instance_guard" {
  count = var.enable_nat ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.nat_mode != "instance" || length(var.nat_instance_azs) > 0
      error_message = "nat_mode = \"instance\" needs at least one AZ in nat_instance_azs, or private subnets get no default route."
    }

    precondition {
      condition     = length(setsubtract(var.nat_instance_azs, var.azs)) == 0
      error_message = "Every nat_instance_azs entry must also appear in azs — a NAT instance needs that AZ's public subnet."
    }

    precondition {
      condition     = length(setsubtract(var.per_az_route_tables, var.azs)) == 0
      error_message = "Every per_az_route_tables entry must also appear in azs — it needs that AZ's private subnet to associate."
    }
  }
}

# Deliberately NOT gated on nat_mode: an instance can exist while the
# gateway still carries traffic. That is what makes the cutover two
# applies — build and verify, then flip the route — instead of one that
# drops egress until a box finishes booting.
module "nat_instance" {
  source   = "../nat-instance"
  for_each = var.enable_nat ? toset(var.nat_instance_azs) : toset([])

  env       = var.env
  az        = each.key
  vpc_id    = aws_vpc.main.id
  subnet_id = aws_subnet.public[each.key].id
  vpc_cidr  = var.cidr_block

  instance_type    = var.nat_instance_type
  alarm_topic_arns = var.nat_alarm_topic_arns
  tags             = var.tags
}

# --- Internal DNS --------------------------------------------------------
#
# ONE private zone per environment, associated with every region's VPC. The
# FIRST region creates it; later regions pass existing_zone_id.
#
# Two same-named zones on peered VPCs collide SILENTLY: a node resolves a
# peer's hostname in its own zone and replicates from the wrong node with a
# healthy-looking link. Sentinel answers with hostnames, so a name must mean
# the same node in every region.

resource "aws_route53_zone" "internal" {
  count = var.existing_zone_id == "" ? 1 : 0

  name = var.internal_dns_zone

  vpc {
    vpc_id = aws_vpc.main.id
  }

  # The zone outlives any single region's VPC: a later region associates
  # with it, and Terraform would otherwise try to drop those associations
  # to match this block.
  lifecycle {
    ignore_changes = [vpc]
  }

  tags = merge(var.tags, {
    Name = "Internal DNS"
  })
}

moved {
  from = aws_route53_zone.internal
  to   = aws_route53_zone.internal[0]
}

# A later region joins the environment's zone. vpc_region is explicit
# because the zone is global while the VPC is not, and the provider's
# region is not necessarily this VPC's.
resource "aws_route53_zone_association" "internal" {
  count = var.existing_zone_id == "" ? 0 : 1

  zone_id    = var.existing_zone_id
  vpc_id     = aws_vpc.main.id
  vpc_region = data.aws_region.current.region
}
