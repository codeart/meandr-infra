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

# --- Reader Valkey -----------------------------------------------------
#
# Region-level resource (not inside meandr-api or meandr-mcp) because both
# apps consume it. Standalone today; promotes to gd_primary when production
# launches a second region. TLS-on from day 1 — required for Global Datastore
# eligibility, can't be toggled in place.

module "reader" {
  source = "../../modules/elasticache-valkey"

  name        = "meandr-reader"
  description = "Reader Valkey staging - proxy reads config, BE writes config"
  role        = "reader"

  engine_version = "8.1"
  node_type      = "cache.t4g.micro"

  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  snapshot_retention_days = 1

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

  hostname  = "staging-api.meandr.com"
  image_tag = "develop"

  vpc_id                 = module.vpc.vpc_id
  vpc_cidr_block         = module.vpc.vpc_cidr_block
  public_subnet_ids      = module.vpc.public_subnet_ids
  private_subnet_ids     = module.vpc.private_subnet_ids
  internal_dns_zone_id   = module.vpc.internal_dns_zone_id
  internal_dns_zone_name = module.vpc.internal_dns_zone_name

  reader_internal_dns_name = module.reader.internal_dns_name
  reader_security_group_id = module.reader.security_group_id
  # writer_internal_dns_name wired in from module.mcp once mcp is uncommented.

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

# mcp_* outputs and writer_internal_dns_name omitted while module.mcp is disabled.
# Re-add once the NLB account-level limit is in place and module.mcp is uncommented.
