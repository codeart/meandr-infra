# staging / eu-central-1 — explicit module list. Onboarding a new region =
# copy this file, change identity vars (env, account, CIDR, hostname) +
# uncomment/comment module blocks per which apps run there.

provider "aws" {
  region  = "eu-central-1"
  profile = "meandr-staging"
}

# meandr.com + meandr.io hosted zones live in the Shared account — used for
# both ACM DNS validation and the public hostname records.
provider "aws" {
  alias   = "shared"
  region  = "eu-central-1"
  profile = "meandr-shared"
}

locals {
  env        = "staging"
  region     = "eu-central-1"
  account_id = "259534890849"

  tags = {
    "meandr:env" = local.env
  }
}

# --- VPC ---------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  cidr_block        = "10.10.0.0/16"
  azs               = ["eu-central-1a", "eu-central-1b"]
  enable_nat        = true
  internal_dns_zone = "${local.env}.meandr.local"

  tags = local.tags
}

# --- Config-plane Valkey -----------------------------------------------
#
# The shared Redis where the BE writes config records (projects, servers,
# agents, policies, tokens, hosts, tools) and the proxy reads them. Lives
# at region level (not inside an app module) because both meandr-api and
# meandr-mcp consume it. Standalone today; promotes to gd_primary when
# production launches a second region. TLS-on from day 1 — required for
# Global Datastore eligibility, can't be toggled in place.
#
# Two DNS records are created by the module:
#   - mcp-redis-in.<region>.staging.meandr.local  → reader endpoint
#   - mcp-redis-out.staging.meandr.local          → writable primary
#
# Read endpoint includes the region because each region's secondary
# cluster has its own replica endpoint. Write endpoint omits region
# because there is only one global GD primary.

module "config_valkey" {
  source = "../../modules/elasticache-valkey"

  # AWS replication_group_id intentionally kept at "meandr-reader" — the
  # legacy name in the AWS console — to avoid a destroy/recreate of the
  # cluster. The customer-visible naming change is in the DNS records
  # below, which is what apps actually connect to.
  name        = "meandr-reader"
  description = "Config Valkey staging - BE writes config, proxy reads config"

  engine_version = "8.1"
  node_type      = "cache.t4g.micro"

  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  snapshot_retention_days = 1

  vpc_id             = module.vpc.vpc_id
  vpc_cidr_block     = module.vpc.vpc_cidr_block
  private_subnet_ids = module.vpc.private_subnet_ids

  tags = merge(local.tags, { "meandr:plane" = "config" })
}

# Local-module rename in state. The underlying AWS resource ID is
# unchanged (still "meandr-reader") so no resource churn — Terraform
# just updates its state-tree addressing.
moved {
  from = module.reader
  to   = module.config_valkey
}

# --- Config-plane DNS --------------------------------------------------
#
# Each consumer app gets its own prefix even when pointing at the same
# physical cluster. Today both prefixes resolve to the shared config
# Valkey; when BE eventually gets its own queue/cache Redis we point
# be-redis-* at the new cluster and proxy is unaffected.
#
#   mcp-redis-in.<region>.<env>.meandr.local  → reader endpoint  (proxy reads)
#   mcp-redis-out.<env>.meandr.local          → primary endpoint (proxy writes, ie. counters/streams once mcp is online)
#   be-redis-in.<region>.<env>.meandr.local   → reader endpoint  (BE reads back its writes for the dashboard)
#   be-redis-out.<env>.meandr.local           → primary endpoint (BE writes config records)
#
# Read records carry the region because each region's GD secondary has
# its own replica endpoint. Write records omit region because there is
# only one global GD primary.

resource "aws_route53_record" "mcp_redis_in" {
  zone_id = module.vpc.internal_dns_zone_id
  name    = "mcp-redis-in.${local.region}.${module.vpc.internal_dns_zone_name}"
  type    = "CNAME"
  ttl     = 60
  records = [module.config_valkey.reader_endpoint_address]
}

resource "aws_route53_record" "mcp_redis_out" {
  zone_id = module.vpc.internal_dns_zone_id
  name    = "mcp-redis-out.${module.vpc.internal_dns_zone_name}"
  type    = "CNAME"
  ttl     = 60
  records = [module.config_valkey.primary_endpoint_address]
}

resource "aws_route53_record" "be_redis_in" {
  zone_id = module.vpc.internal_dns_zone_id
  name    = "be-redis-in.${local.region}.${module.vpc.internal_dns_zone_name}"
  type    = "CNAME"
  ttl     = 60
  records = [module.config_valkey.reader_endpoint_address]
}

resource "aws_route53_record" "be_redis_out" {
  zone_id = module.vpc.internal_dns_zone_id
  name    = "be-redis-out.${module.vpc.internal_dns_zone_name}"
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

  hostname  = "staging-api.meandr.com"
  image_tag = "develop"

  vpc_id                 = module.vpc.vpc_id
  vpc_cidr_block         = module.vpc.vpc_cidr_block
  public_subnet_ids      = module.vpc.public_subnet_ids
  private_subnet_ids     = module.vpc.private_subnet_ids
  internal_dns_zone_id   = module.vpc.internal_dns_zone_id
  internal_dns_zone_name = module.vpc.internal_dns_zone_name

  reader_internal_dns_name = aws_route53_record.be_redis_in.fqdn
  writer_internal_dns_name = aws_route53_record.be_redis_out.fqdn
  reader_security_group_id = module.config_valkey.security_group_id

  db_instance_class = "db.t4g.micro"
  puma    = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 70 }
  jobs    = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 70 }
  migrate = { cpu = 512, memory = 1024 }
}

# --- meandr-mcp --------------------------------------------------------
#
# Proxy stack: writer Valkey + NLB + ECS cluster + proxy service. NLB has
# two plain TCP listeners (80 + 443) forwarding to proxy:8080; proxy
# terminates TLS itself once the BE-side cert pipeline lands (Phase 2).
# Customer HTTPS traffic won't work end-to-end until then — expected v0.

# Temporarily disabled while AWS Support processes the NLB account-level
# limit increase. Uncomment to re-provision once the limit is in place.
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
#   image_tag = "develop"
#
#   vpc_id                 = module.vpc.vpc_id
#   vpc_cidr_block         = module.vpc.vpc_cidr_block
#   public_subnet_ids      = module.vpc.public_subnet_ids
#   private_subnet_ids     = module.vpc.private_subnet_ids
#   internal_dns_zone_id   = module.vpc.internal_dns_zone_id
#   internal_dns_zone_name = module.vpc.internal_dns_zone_name
#
#   reader_internal_dns_name = module.reader.internal_dns_name
#
#   writer_node_type = "cache.t4g.micro"
#   proxy            = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 60 }
# }

# --- Outputs -----------------------------------------------------------

output "vpc_id"             { value = module.vpc.vpc_id }
output "vpc_cidr_block"     { value = module.vpc.vpc_cidr_block }
output "public_subnet_ids"  { value = module.vpc.public_subnet_ids }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }

output "mcp_redis_in_dns"  { value = aws_route53_record.mcp_redis_in.fqdn }
output "mcp_redis_out_dns" { value = aws_route53_record.mcp_redis_out.fqdn }
output "be_redis_in_dns"   { value = aws_route53_record.be_redis_in.fqdn }
output "be_redis_out_dns"  { value = aws_route53_record.be_redis_out.fqdn }
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

# mcp_* outputs and writer_internal_dns_name omitted while module.mcp is disabled.
# Re-add once the NLB account-level limit is in place and module.mcp is uncommented.
