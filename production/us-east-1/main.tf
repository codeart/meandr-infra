# production / us-east-1 — primary region. Hosts the BE; will also host MCP
# once the proxy code ships. EU + other regions become mcp-only secondaries.
#
# Status: NOT YET APPLIED. Scaffolded here so the shape mirrors staging.
# Sizing is initial-production conservative; tune before first apply.
#
# *** PRODUCTION WORKLOAD DEFERRED ***
#
# Everything below (VPC, config_stream, creds, KMS, meandr-api, meandr-mcp,
# and the related outputs) is wrapped in /* */ block comments so `terraform
# apply` here is a no-op. The intent: routine TF activity (re-init, plan
# checks, sibling-module edits) doesn't accidentally trigger production
# bring-up. When ready for the planned production launch:
#   1. Remove the two `/* WORKLOAD-DEFERRED START */` and
#      `/* WORKLOAD-DEFERRED END */` markers (one wraps modules, one wraps
#      outputs).
#   2. Have prereqs in hand: config/credentials/production.key for
#      rails-master-key, a *.meandr.io cert ready to upload after first
#      apply, headspace for the bring-up event.
#   3. `terraform apply` — expect ~95 resources created.
#
# Account-level policy work (cost alerts, IAM, anomaly detection,
# org-wide SCP) lives in account-master/ and account-production/, NOT
# here — those states are live and applicable independently of this one.

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

/* WORKLOAD-DEFERRED START — modules wrapped until first-deploy day; see header.

# --- VPC ---------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  cidr_block        = "10.20.0.0/16"
  azs               = ["us-east-1a", "us-east-1b"]
  enable_nat        = true
  internal_dns_zone = "${local.env}.meandr.local"

  tags = local.tags
}

# --- Config-stream Valkey ----------------------------------------------
#
# GD-eligible node family (r-series) so we can attach secondaries later
# without rebuild. Multi-AZ replication with auto failover. TLS-on
# (required for GD). When the second proxy region comes online, this
# becomes the GD primary; secondaries reference its global RG ID via
# remote state. For now, standalone.
#
# Cluster name `meandr-config-stream` matches the role: config records
# (BE writes / proxy reads) + the `<env>:in` event stream (BE produces /
# proxy consumes). Both apps connect to AWS-internal hostnames directly
# so the cluster's wildcard cert verifies cleanly — no CNAME aliasing.

module "config_stream" {
  source = "../../modules/elasticache-valkey"

  name        = "meandr-config-stream"
  description = "Config-stream Valkey production - BE writes config + inbound events, proxy reads config + consumes inbound events"

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

# --- Credential store (Dynamo + KMS envelope) --------------------------
#
# Production cred-store. Multi-region replication is empty for now
# (single proxy region today) — add region codes here when secondary
# proxy regions come online and AWS spins up Global Tables replicas.
#
# PITR + deletion protection on: cred rotations are audit-relevant and
# irrecoverable if the blob is destroyed (the AEAD plaintext only
# exists in BE memory between rotations). 35-day continuous backup
# window + explicit destroy guard.

module "creds_table" {
  source = "../../modules/dynamodb-creds-table"

  name = "meandr-creds-${local.env}"

  replica_regions             = [] # add eu-central-1 etc. when proxy goes multi-region
  pitr_enabled                = true
  deletion_protection_enabled = true

  tags = local.tags
}

module "cred_encryption_key" {
  source = "../../modules/cred-encryption-key"

  env        = local.env
  alias_name = "meandr-cred-${local.env}"

  enable_key_rotation     = true
  deletion_window_in_days = 30 # production: max window for ScheduleKeyDeletion safety

  tags = local.tags
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

  config_writer_endpoint          = module.config_stream.primary_endpoint_address
  config_stream_security_group_id = module.config_stream.security_group_id

  # State-plane regions BE should consume streams from. Empty until the
  # MCP module is uncommented below — at that point both lists pick up
  # the local region (and event-stream writer endpoint).
  regions                = []
  event_writer_endpoints = []

  cred_store_enabled        = true
  creds_table_name          = module.creds_table.table_name
  creds_table_arn           = module.creds_table.table_arn
  cred_encryption_key_arn   = module.cred_encryption_key.key_arn
  cred_encryption_key_alias = module.cred_encryption_key.alias_name

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

WORKLOAD-DEFERRED END (modules) */

# --- meandr-mcp (not deployed yet — uncomment when proxy code is ready) -
#
# When uncommented:
#   1. Set regions + event_writer_endpoints on module.api above:
#        regions                = [local.region]
#        event_writer_endpoints = [module.mcp.event_writer_endpoint]
#   2. Apply to provision event-stream Valkey + NLB + idle proxy service.
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
#   config_reader_endpoint = module.config_stream.reader_endpoint_address
#
#   cred_store_enabled      = true
#   creds_table_name        = module.creds_table.table_name
#   creds_table_arn         = module.creds_table.table_arn
#   cred_encryption_key_arn = module.cred_encryption_key.key_arn
#
#   event_stream_node_type             = "cache.t4g.small"  # bump above staging; event stream can take more load
#   event_stream_snapshot_retention_days = 7
#   proxy = { cpu = 512, memory = 1024, desired_count = 2, min_replicas = 2, max_replicas = 20, target_cpu_utilization = 60 }
# }

# --- Outputs -----------------------------------------------------------

/* WORKLOAD-DEFERRED START — outputs wrapped until first-deploy day; see header.

output "vpc_id"             { value = module.vpc.vpc_id }
output "vpc_cidr_block"     { value = module.vpc.vpc_cidr_block }
output "public_subnet_ids"  { value = module.vpc.public_subnet_ids }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }

output "config_stream_writer_endpoint" { value = module.config_stream.primary_endpoint_address }
output "config_stream_reader_endpoint" { value = module.config_stream.reader_endpoint_address }
# event_stream_writer_endpoint is exposed by module.mcp once uncommented.

output "hostname"             { value = module.api.hostname }
output "alb_dns_name"         { value = module.api.alb_dns_name }
output "cluster_name"         { value = module.api.cluster_name }
output "puma_service_name"    { value = module.api.puma_service_name }
output "jobs_service_name"    { value = module.api.jobs_service_name }
output "migrate_task_family"  { value = module.api.migrate_task_family }
output "worker_sg_id"         { value = module.api.worker_security_group_id }
output "rds_internal_dns_name" { value = module.api.rds_internal_dns_name }

WORKLOAD-DEFERRED END (outputs) */
