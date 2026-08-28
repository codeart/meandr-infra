# One Valkey fleet: m+s in AZ-a, r+s in AZ-b, s-only arbiter in AZ-c.
#
# Region role changes exactly one thing — whether a node may be promoted.
# Shape is identical everywhere, which is what makes primary a movable
# property rather than a rebuild. See valkey_fleets.md §1.

locals {
  azs = ["a", "b", "c"]

  common = {
    valkey_version       = var.valkey_version
    valkey_source_bucket = var.valkey_source_bucket
    valkey_source_sha256 = var.valkey_source_sha256
    instance_type        = var.instance_type
    create_timeout       = var.create_timeout
    auth_secret_arn      = var.auth_secret_arn
    tls_secret_arn       = var.tls_secret_arn
    vpc_id               = var.vpc_id
    client_cidrs         = var.client_cidrs
    dns_zone_id          = var.dns_zone_id
    dns_zone_name        = var.dns_zone_name
  }
}

module "a" {
  source = "../valkey-node"

  fleet = var.fleet
  node  = "${var.region_code}a"

  # Bootstrap tie-break only, used before a master record resolves. After
  # that every boot derives its role from the record.
  role                = var.promotable ? "master" : "replica"
  promotable          = var.promotable
  master_record_label = var.master_record_label

  maxmemory_percent = var.maxmemory_percent
  maxmemory_policy  = var.maxmemory_policy
  backup_bucket     = var.backup_bucket

  run_sentinel    = true
  sentinel_quorum = var.sentinel_quorum

  subnet_id = var.subnet_ids[0]

  valkey_version       = local.common.valkey_version
  valkey_source_bucket = local.common.valkey_source_bucket
  valkey_source_sha256 = local.common.valkey_source_sha256
  instance_type        = local.common.instance_type
  create_timeout       = local.common.create_timeout
  auth_secret_arn      = local.common.auth_secret_arn
  tls_secret_arn       = local.common.tls_secret_arn
  vpc_id               = local.common.vpc_id
  client_cidrs         = local.common.client_cidrs
  dns_zone_id          = local.common.dns_zone_id
  dns_zone_name        = local.common.dns_zone_name

  tags = merge(var.tags, { "meandr:plane" = var.fleet })
}

module "b" {
  source = "../valkey-node"

  fleet = var.fleet
  node  = "${var.region_code}b"

  role                = "replica"
  promotable          = var.promotable
  master_record_label = var.master_record_label

  maxmemory_percent = var.maxmemory_percent
  maxmemory_policy  = var.maxmemory_policy
  backup_bucket     = var.backup_bucket

  run_sentinel    = true
  sentinel_quorum = var.sentinel_quorum

  # AZ-b is the point of the pair.
  subnet_id = var.subnet_ids[1]

  valkey_version       = local.common.valkey_version
  valkey_source_bucket = local.common.valkey_source_bucket
  valkey_source_sha256 = local.common.valkey_source_sha256
  instance_type        = local.common.instance_type
  create_timeout       = local.common.create_timeout
  auth_secret_arn      = local.common.auth_secret_arn
  tls_secret_arn       = local.common.tls_secret_arn
  vpc_id               = local.common.vpc_id
  client_cidrs         = local.common.client_cidrs
  dns_zone_id          = local.common.dns_zone_id
  dns_zone_name        = local.common.dns_zone_name

  tags = merge(var.tags, { "meandr:plane" = var.fleet })
}

# Arbiter: Sentinel only, no valkey-server. Third vote in a third AZ, so
# losing a zone never costs two of three. maxmemory_* are inert while
# sentinel_only holds, carried so clearing that flag needs no other edit.
module "c" {
  source = "../valkey-node"

  fleet = var.fleet
  node  = "${var.region_code}c"

  role                = "replica"
  promotable          = var.promotable
  sentinel_only       = true
  master_record_label = var.master_record_label

  maxmemory_percent = var.maxmemory_percent
  maxmemory_policy  = var.maxmemory_policy

  run_sentinel    = true
  sentinel_quorum = var.sentinel_quorum

  subnet_id = var.subnet_ids[2]

  valkey_version       = local.common.valkey_version
  valkey_source_bucket = local.common.valkey_source_bucket
  valkey_source_sha256 = local.common.valkey_source_sha256
  instance_type        = var.arbiter_instance_type
  create_timeout       = local.common.create_timeout
  auth_secret_arn      = local.common.auth_secret_arn
  tls_secret_arn       = local.common.tls_secret_arn
  vpc_id               = local.common.vpc_id
  client_cidrs         = local.common.client_cidrs
  dns_zone_id          = local.common.dns_zone_id
  dns_zone_name        = local.common.dns_zone_name

  tags = merge(var.tags, { "meandr:plane" = var.fleet })
}

# Terraform bootstraps the record because Sentinel only writes it on a
# FAILOVER; ownership then passes to Sentinel, which is what ignore_changes
# protects. An edge must not create it for a fleet whose master is global.
resource "aws_route53_record" "master" {
  count = var.create_master_record ? 1 : 0

  zone_id = var.dns_zone_id
  name    = module.a.master_hostname
  type    = "CNAME"
  ttl     = 5
  records = [module.a.hostname]

  lifecycle {
    ignore_changes = [records]
  }
}
