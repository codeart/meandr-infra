# production / us-east-1 — primary region. Hosts the BE; will also host MCP
# once the proxy code ships. EU + other regions become mcp-only secondaries.
#
# Status: NOT YET APPLIED. Scaffolded here so the shape mirrors staging.
# Sizing is initial-production conservative; tune before first apply.

provider "aws" {
  region  = "us-east-1"
  profile = "meandr-production"
}

# meandr.com + meandr.io hosted zones live in the Shared account.
provider "aws" {
  alias   = "shared"
  region  = "eu-central-1"
  profile = "meandr-shared"
}

locals {
  env        = "production"
  region     = "us-east-1"
  account_id = "393686273464"

  tags = {
    "meandr:env" = local.env
  }
}

# --- VPC ---------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  cidr_block        = "10.20.0.0/16"
  azs               = ["us-east-1a", "us-east-1b"]
  enable_nat        = true
  internal_dns_zone = "${local.env}.meandr.local"

  tags = local.tags
}

# --- Config-plane Valkey -----------------------------------------------
#
# GD-eligible node family (r-series) so we can attach secondaries later
# without rebuild. Multi-AZ replication with auto failover. TLS-on
# (required for GD). When the second proxy region comes online, this
# becomes the GD primary; secondaries reference its global RG ID via
# remote state. For now, standalone.
#
# Two DNS records (created by the module):
#   mcp-redis-in.<region>.production.meandr.local  → reader endpoint
#   mcp-redis-out.production.meandr.local          → primary endpoint

module "config_valkey" {
  source = "../../modules/elasticache-valkey"

  # Keep AWS replication_group_id at "meandr-reader" to avoid a destroy
  # on rename. The customer-visible naming is in the DNS records below.
  name        = "meandr-reader"
  description = "Config Valkey production - BE writes config, proxy reads config"

  engine_version = "8.1"
  node_type      = "cache.r7g.large"

  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  snapshot_retention_days = 7

  vpc_id             = module.vpc.vpc_id
  vpc_cidr_block     = module.vpc.vpc_cidr_block
  private_subnet_ids = module.vpc.private_subnet_ids

  tags = merge(local.tags, { "meandr:plane" = "config" })
}

# Local-module rename in state. The underlying AWS resource ID is
# unchanged (still "meandr-reader") so no resource churn.
moved {
  from = module.reader
  to   = module.config_valkey
}

# --- Reader-cluster DNS ------------------------------------------------
#
# See the staging caller for the full naming rationale. Reader cluster
# holds config records (BE writes, proxy reads); writer-cluster records
# live inside module.mcp.

resource "aws_route53_record" "mcp_redis_in" {
  zone_id = module.vpc.internal_dns_zone_id
  name    = "mcp-redis-in.${local.region}.${module.vpc.internal_dns_zone_name}"
  type    = "CNAME"
  ttl     = 60
  records = [module.config_valkey.reader_endpoint_address]
}

resource "aws_route53_record" "be_redis_out" {
  zone_id = module.vpc.internal_dns_zone_id
  name    = "be-redis-out.${local.region}.${module.vpc.internal_dns_zone_name}"
  type    = "CNAME"
  ttl     = 60
  records = [module.config_valkey.primary_endpoint_address]
}

# --- meandr-api --------------------------------------------------------

module "api" {
  source = "../../modules/meandr-api"

  providers = {
    aws     = aws
    aws.dns = aws.shared
  }

  env        = local.env
  account_id = local.account_id

  hostname  = "api.meandr.com"
  image_tag = "main"

  vpc_id                 = module.vpc.vpc_id
  vpc_cidr_block         = module.vpc.vpc_cidr_block
  public_subnet_ids      = module.vpc.public_subnet_ids
  private_subnet_ids     = module.vpc.private_subnet_ids
  internal_dns_zone_id   = module.vpc.internal_dns_zone_id
  internal_dns_zone_name = module.vpc.internal_dns_zone_name

  writer_internal_dns_name = aws_route53_record.be_redis_out.fqdn
  reader_security_group_id = module.config_valkey.security_group_id

  # State-plane regions BE should consume streams from. Just primary
  # today; expand to include eu-central-1 once that region's meandr-mcp
  # is provisioned.
  regions = [local.region]

  # Production sizing — conservative starting point; revisit after first weeks of real traffic.
  db_instance_class           = "db.t4g.medium"
  db_allocated_storage_gb     = 50
  db_max_allocated_storage_gb = 500
  db_multi_az                 = true
  db_backup_retention_days    = 14
  db_deletion_protection      = true

  puma    = { cpu = 512, memory = 1024, desired_count = 2, min_replicas = 2, max_replicas = 10, target_cpu_utilization = 70 }
  jobs    = { cpu = 512, memory = 1024, desired_count = 2, min_replicas = 2, max_replicas = 10, target_cpu_utilization = 70 }
  migrate = { cpu = 1024, memory = 2048 }
}

# --- meandr-mcp (not deployed yet — uncomment when proxy code is ready) -
#
# When uncommented:
#   1. Apply this region to provision writer Valkey + NLB + idle proxy service.
#   2. Wire `writer_internal_dns_name = module.mcp.writer_internal_dns_name`
#      into module.api above so BE picks up the local writer endpoint.
#   3. Push a real image; set proxy.desired_count >= 2 and re-apply.
#
# module "mcp" {
#   source = "../../modules/meandr-mcp"
#
#   providers = {
#     aws     = aws
#     aws.dns = aws.shared
#   }
#
#   env        = local.env
#   account_id = local.account_id
#
#   image_tag = "main"
#
#   vpc_id                 = module.vpc.vpc_id
#   vpc_cidr_block         = module.vpc.vpc_cidr_block
#   public_subnet_ids      = module.vpc.public_subnet_ids
#   private_subnet_ids     = module.vpc.private_subnet_ids
#   internal_dns_zone_id   = module.vpc.internal_dns_zone_id
#   internal_dns_zone_name = module.vpc.internal_dns_zone_name
#
#   reader_internal_dns_name = aws_route53_record.mcp_redis_in.fqdn
#
#   writer_node_type             = "cache.t4g.small"  # bump above staging; writer can take more load
#   writer_snapshot_retention_days = 7
#   proxy = { cpu = 512, memory = 1024, desired_count = 2, min_replicas = 2, max_replicas = 20, target_cpu_utilization = 60 }
# }

# --- Outputs -----------------------------------------------------------

output "vpc_id"             { value = module.vpc.vpc_id }
output "vpc_cidr_block"     { value = module.vpc.vpc_cidr_block }
output "public_subnet_ids"  { value = module.vpc.public_subnet_ids }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }

output "mcp_redis_in_dns" { value = aws_route53_record.mcp_redis_in.fqdn }
output "be_redis_out_dns" { value = aws_route53_record.be_redis_out.fqdn }
# mcp_redis_out / be_redis_in records are created inside module.mcp
# (writer cluster); not exposed here until that module is uncommented.
output "config_redis_primary_endpoint" { value = module.config_valkey.primary_endpoint_address }
output "config_redis_reader_endpoint"  { value = module.config_valkey.reader_endpoint_address }

output "hostname"             { value = module.api.hostname }
output "alb_dns_name"         { value = module.api.alb_dns_name }
output "cluster_name"         { value = module.api.cluster_name }
output "puma_service_name"    { value = module.api.puma_service_name }
output "jobs_service_name"    { value = module.api.jobs_service_name }
output "migrate_task_family"  { value = module.api.migrate_task_family }
output "worker_sg_id"         { value = module.api.worker_security_group_id }
output "rds_internal_dns_name" { value = module.api.rds_internal_dns_name }
