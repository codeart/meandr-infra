# ElastiCache Valkey module — reusable for reader + writer roles.
#
# Why Valkey (not Redis OSS):
#   - License-free fork backed by Linux Foundation, AWS, Google, Oracle
#   - ~20% cheaper on ElastiCache than Redis OSS for the same node class
#   - Wire-compatible (RESP); clients (go-redis etc.) don't know the difference
#   - Migration back to Redis OSS is mechanical via snapshot restore — see
#     docs/deployment_strategy.md for the conversion path
#
# This module creates the cluster + SG + subnet group only. DNS records
# are caller-owned — each consumer app should have its own prefix
# (mcp-redis-in/out for the proxy, be-redis-in/out for BE) pointing at
# the cluster's exposed `reader_endpoint_address` / `primary_endpoint_address`.
# Direction (-in/-out) is named from the consumer's perspective: -in is
# "data flowing into me" (read), -out is "data flowing out of me" (write).
#
# AUTH tokens are NOT used. SG + private-subnet placement is the trust boundary.
# This matches deployment_strategy.md §6: "in-VPC isolation is the trust model;
# auth tokens add ops complexity for marginal benefit when nothing internet-
# facing can reach the cluster."

# --- Networking ----------------------------------------------------------

resource "aws_elasticache_subnet_group" "main" {
  name       = var.name
  subnet_ids = var.private_subnet_ids
  description = "Subnets for ${var.name}"

  tags = merge(var.tags, {
    Name = "${var.name} subnets"
  })
}

resource "aws_security_group" "main" {
  name        = "${var.name}-cache"
  description = "Valkey access for ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name} cache SG"
  })

  # AWS marks aws_security_group.description as ForceNew, so any tweak
  # to the description string (e.g. dropping the old `(reader)` suffix
  # during the in/out rename) would replace the SG — which in turn
  # forces the cluster to swap its SG attachment. Description is purely
  # cosmetic console metadata; ignore changes to avoid that churn.
  lifecycle {
    ignore_changes = [description]
  }
}

resource "aws_security_group_rule" "ingress_vpc" {
  type              = "ingress"
  security_group_id = aws_security_group.main.id

  from_port   = 6379
  to_port     = 6379
  protocol    = "tcp"
  cidr_blocks = [var.vpc_cidr_block]
  description = "Valkey from within VPC"
}

resource "aws_security_group_rule" "egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.main.id

  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
  description = "Allow all outbound"
}

# --- Replication group ---------------------------------------------------

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = var.name
  description          = var.description

  engine         = "valkey"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = 6379

  num_cache_clusters         = var.num_cache_clusters
  automatic_failover_enabled = var.automatic_failover_enabled
  multi_az_enabled           = var.multi_az_enabled

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.main.id]

  transit_encryption_enabled = var.transit_encryption_enabled
  at_rest_encryption_enabled = var.at_rest_encryption_enabled

  snapshot_retention_limit = var.snapshot_retention_days
  snapshot_window          = "03:00-04:00" # UTC; aligns with RDS backup window
  maintenance_window       = "mon:04:00-mon:05:00"

  auto_minor_version_upgrade = true
  apply_immediately          = true

  tags = merge(var.tags, {
    Name = var.name
  })
}

# DNS is caller-owned — no Route53 resources here. See file header.
