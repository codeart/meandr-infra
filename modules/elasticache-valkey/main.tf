# ElastiCache Valkey module — reusable for reader + writer roles.
#
# Why Valkey (not Redis OSS):
#   - License-free fork backed by Linux Foundation, AWS, Google, Oracle
#   - ~20% cheaper on ElastiCache than Redis OSS for the same node class
#   - Wire-compatible (RESP); clients (go-redis etc.) don't know the difference
#   - Migration back to Redis OSS is mechanical via snapshot restore — see
#     docs/deployment_strategy.md for the conversion path
#
# Two operating modes via `role`:
#   - reader: TLS in-transit ON (Global Datastore prerequisite), regional cache
#     of config records served to the proxy. Production will eventually upgrade
#     to GD-eligible node family (R/M series) and replicate cross-region.
#   - writer: TLS off (single-region, no GD), source of truth for writes coming
#     from meandr-api. Streams invalidations on `inv` to the reader replicas.
#
# AUTH tokens are NOT used. SG + private-subnet placement is the trust boundary.
# This matches deployment_strategy.md §6: "in-VPC isolation is the trust model;
# auth tokens add ops complexity for marginal benefit when nothing internet-
# facing can reach the cluster."

# --- Networking ----------------------------------------------------------

resource "aws_elasticache_subnet_group" "main" {
  name       = var.name
  subnet_ids = var.private_subnet_ids
  description = "Subnets for ${var.name} (${var.role})"

  tags = merge(var.tags, {
    Name = "${var.name} subnets"
  })
}

resource "aws_security_group" "main" {
  name        = "${var.name}-cache"
  description = "Valkey access for ${var.name} (${var.role})"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name} cache SG"
  })
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
    Name = "${var.name} ${var.role}"
  })
}

# --- Internal DNS --------------------------------------------------------

resource "aws_route53_record" "primary" {
  zone_id = var.internal_dns_zone_id
  name    = "redis-${var.role}.${var.internal_dns_zone_name}"
  type    = "CNAME"
  ttl     = 60
  records = [aws_elasticache_replication_group.main.primary_endpoint_address]
}
