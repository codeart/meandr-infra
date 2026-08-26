# VPC module — reusable across envs/regions.
#
# Each AZ gets:
#   - One /24 public subnet  (for NAT GW, ALB; 256 addresses each)
#   - One /20 private subnet (for workloads, ECS task ENIs, RDS, ElastiCache; 4096 addresses each)
#
# CIDR layout for a /16 VPC:
#   Public  AZ-index i:  cidrsubnet(cidr, 8, i)        → /24
#   Private AZ-index i:  cidrsubnet(cidr, 4, 1 + i)    → /20 starting at .16
#
# Single NAT Gateway when enable_nat is true (cost vs. HA trade-off; multi-NAT
# for production HA is a future flag).
#
# Internal DNS: one Route 53 private hosted zone per VPC. Future RDS / ElastiCache
# / EC2 modules add CNAMEs/A records here so connection strings can use friendly,
# env-tagged hostnames like `pg.staging.meandr.internal`.

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
# Unconditional and free. Gateway endpoints are route-table entries, not
# PrivateLink interfaces: no hourly charge, no per-GB charge, no ENIs, no
# security groups.
#
# Without them, every byte a private-subnet workload sends to S3 or DynamoDB
# egresses through the NAT Gateway and pays NAT data processing (~$0.045/GB,
# the same rate quoted on var.enable_nat). That is the dominant cost line for
# the capture pipeline, which writes every request body to S3:
#
#     1 TB/month captured        →   ~$45/month in NAT processing
#     10 GB/minute (~432 TB/mo)  →  ~$19,400/month
#
# The proxy also reads upstream credentials from DynamoDB on the request path
# (cred-store), so both services belong here.
#
# Created even when enable_nat is false: with no NAT, these are the *only*
# route to S3/DynamoDB from a private subnet, which is precisely when they
# matter most.
#
# Private route table only. Public subnets host the NAT Gateway and the ALB,
# no workloads, and they reach S3 via the Internet Gateway at no data
# processing charge — so an association there would buy nothing.
#
# No endpoint policy attached: the default is full access, and access is
# already constrained by the task roles. A restrictive endpoint policy is a
# second place to get bucket permissions wrong.

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
# REGIONAL NAT in manual mode: one gateway for the VPC, holding addresses
# in `nat_pinned_azs` only, and serving every AZ — including the ones it
# holds no address in. Traffic from an unpinned AZ is processed by an
# address in a pinned one.
#
# Manual mode is the whole point. Supplying availability_zone_address
# DISABLES auto-expansion permanently: the gateway will not quietly add an
# address in a new AZ when a workload appears there. That keeps the bill
# and the egress IP set fixed and predictable — an allow-list on a
# customer's firewall stays correct, which auto-expansion cannot promise.
#
# The cost shape is the reason to pin fewer AZs than the VPC spans: AZ-c
# holds only a Sentinel arbiter, which needs no egress at steady state, so
# paying for an address there buys nothing.

# Deliberately NOT the old `aws_eip.nat` / `aws_nat_gateway.main`
# addresses. Provider 6.61 cannot plan a zonal -> regional transition on an
# existing gateway: it fails during diff with
#
#   setting regional_nat_gateway_auto_mode to ForceNew:
#   ForceNew: No changes for regional_nat_gateway_auto_mode
#
# and -replace hits the same path, so there is no way to express the change
# in place. New addresses make it an ordinary create instead: Terraform
# builds the regional gateway, repoints the route, then tears down the
# zonal one — so egress is only interrupted for the route update rather
# than for the minutes a NAT takes to delete and recreate.
#
# The egress IP changes as a result, because an EIP cannot be attached to
# two gateways at once. Fine here; a region with customer allow-lists would
# want the slower reuse instead.

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
# ONE private hosted zone per environment, associated with every region's
# VPC — not one zone per region sharing a name.
#
# That distinction is the whole design. Two same-named private zones on
# peered VPCs is a collision, and the failure is silent rather than loud:
# a node told to replicate from `config-euc1a.valkey.<zone>` resolves it in
# its OWN zone and attaches to whatever lives there, with no error and a
# healthy-looking replication link. Sentinel makes it worse, because it
# answers with hostnames — so every name it can return has to mean the same
# node everywhere, which is a property of the zone, not of any record.
#
# The FIRST region creates the zone. Every later region passes
# existing_zone_id and associates instead. A region that creates its own is
# the bug this is built to prevent.
#
# `moved` below, not a rewrite: adding count to a live zone would otherwise
# read as destroy-and-recreate, taking every record with it.

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
