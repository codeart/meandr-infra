# CIDR layout for a /16, per AZ index i:
#   Public   cidrsubnet(cidr, 8, i)      -> /24, NAT and load balancers
#   Private  cidrsubnet(cidr, 4, 1 + i)  -> /20, workloads, starts at .16

locals {
  # Subnet CIDRs derived from the VPC's /16:
  #   public  : /24 chunks at .0, .1, .2 (one per AZ)
  #   private : /20 chunks at .16, .32, .48 (one per AZ)
  public_cidrs  = [for i, _ in var.azs : cidrsubnet(var.cidr_block, 8, i)]
  private_cidrs = [for i, _ in var.azs : cidrsubnet(var.cidr_block, 4, 1 + i)]
}

# --- VPC -----------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block = var.cidr_block

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "Main VPC"
  })
}

# --- Internet Gateway (public subnets' egress) ---------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "Main IGW"
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

resource "aws_route" "private_nat" {
  count = var.enable_nat ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.regional[0].id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
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
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(var.tags, {
    Name = "S3 Gateway Endpoint"
  })
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

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

resource "aws_nat_gateway" "regional" {
  count = var.enable_nat ? 1 : 0

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
    Name = "Main NAT"
  })

  depends_on = [aws_internet_gateway.main]
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
