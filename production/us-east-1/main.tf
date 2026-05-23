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

# --- Reader Valkey -----------------------------------------------------
#
# GD-eligible node family (r-series) so we can attach secondaries later without
# rebuild. Multi-AZ replication with auto failover. TLS-on (required for GD).
#
# When the second proxy region comes online, this becomes the GD primary;
# secondaries reference its global RG ID via remote state. For now, standalone.

module "reader" {
  source = "../../modules/elasticache-valkey"

  name        = "meandr-reader"
  description = "Reader Valkey production - proxy reads config, BE writes config"
  role        = "reader"

  engine_version = "8.1"
  node_type      = "cache.r7g.large"

  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  snapshot_retention_days = 7

  vpc_id                 = module.vpc.vpc_id
  vpc_cidr_block         = module.vpc.vpc_cidr_block
  private_subnet_ids     = module.vpc.private_subnet_ids
  internal_dns_zone_id   = module.vpc.internal_dns_zone_id
  internal_dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:role" = "reader" })
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

  reader_internal_dns_name = module.reader.internal_dns_name
  reader_security_group_id = module.reader.security_group_id
  # writer_internal_dns_name wired in from module.mcp once mcp is uncommented.

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
#   reader_internal_dns_name = module.reader.internal_dns_name
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

output "reader_internal_dns_name" { value = module.reader.internal_dns_name }
output "reader_endpoint"          { value = module.reader.primary_endpoint_address }

output "hostname"             { value = module.api.hostname }
output "alb_dns_name"         { value = module.api.alb_dns_name }
output "cluster_name"         { value = module.api.cluster_name }
output "puma_service_name"    { value = module.api.puma_service_name }
output "jobs_service_name"    { value = module.api.jobs_service_name }
output "migrate_task_family"  { value = module.api.migrate_task_family }
output "worker_sg_id"         { value = module.api.worker_security_group_id }
output "rds_internal_dns_name" { value = module.api.rds_internal_dns_name }
