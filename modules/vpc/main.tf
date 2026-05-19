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
# env-tagged hostnames like `pg.staging.meandr.local`.

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

# Single public route table — all public subnets route to IGW.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "Public Routes"
  })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private route table — has a 0.0.0.0/0 → NAT route IFF NAT is enabled.
# Without NAT, private subnets can only reach the VPC's CIDR + AWS service endpoints
# (if VPC endpoints are added later). That's intentional for cost-free "VPC only" envs.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = var.enable_nat ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.main[0].id
    }
  }

  tags = merge(var.tags, {
    Name = "Private Routes"
  })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# --- NAT Gateway (conditional) -------------------------------------------
#
# Single NAT, in the first AZ's public subnet. Cheaper than per-AZ NAT but
# means private workloads in other AZs egress cross-AZ ($0.01/GB inter-AZ
# transfer). Acceptable for staging; production should consider multi-NAT
# when traffic grows.

resource "aws_eip" "nat" {
  count = var.enable_nat ? 1 : 0

  domain = "vpc"

  tags = merge(var.tags, {
    Name = "NAT EIP"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count = var.enable_nat ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[var.azs[0]].id

  tags = merge(var.tags, {
    Name = "Main NAT"
  })

  depends_on = [aws_internet_gateway.main]
}

# --- Internal DNS --------------------------------------------------------
#
# Private hosted zone scoped to this VPC. Future modules (RDS, ElastiCache,
# EC2 Redis) add records here. Connection strings use env-tagged hostnames
# like `pg.staging.meandr.local` so cross-env config accidents are obvious.

resource "aws_route53_zone" "internal" {
  name = var.internal_dns_zone

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = merge(var.tags, {
    Name = "Internal DNS"
  })
}
