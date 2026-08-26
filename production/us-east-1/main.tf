# production / us-east-1 — primary region. Hosts the BE; will also host MCP
# once the proxy code ships. EU + other regions become mcp-only secondaries.
#
# Status: PARTIALLY APPLIED (2026-08-03). The capture buckets and the
# payload CMK they encrypt with are LIVE; everything else is still
# deferred. Sizing is initial-production conservative; tune before first
# apply of the rest.
#
# Why those three and nothing else: S3's namespace is GLOBAL, so a bucket
# name is claimable by any AWS account on earth until we hold it. Empty
# buckets bill nothing and the CMK is ~$1/month, which production needs
# eventually anyway — cheap insurance against having to rename at launch.
#
# *** THE REST OF THE PRODUCTION WORKLOAD IS DEFERRED ***
#
# VPC, config_stream, creds, meandr-api, meandr-mcp and their outputs are
# wrapped in /* */ block comments so `terraform apply` here creates
# nothing new. The intent: routine TF activity (re-init, plan checks,
# sibling-module edits) doesn't accidentally trigger production bring-up.
# When ready for the planned production launch:
#   1. Remove the two `/* WORKLOAD-DEFERRED START */` and
#      `/* WORKLOAD-DEFERRED END */` markers (one wraps modules, one wraps
#      outputs).
#   2. Have prereqs in hand: config/credentials/production.key for
#      rails-master-key, a *.meandr.io cert ready to upload after first
#      apply, headspace for the bring-up event.
#   3. `terraform apply` — expect ~95 resources created (the buckets and
#      the payload CMK are already there and will not reappear).
#
# Account-level policy work (cost alerts, IAM, anomaly detection,
# org-wide SCP) lives in account-master/ and account-production/, NOT
# here — those states are live and applicable independently of this one.

provider "aws" {
  region  = local.region
  profile = "meandr-production"
}

# meandr.com + meandr.io hosted zones live in the Shared account.
provider "aws" {
  alias   = "shared"
  region  = "eu-central-1"
  profile = "meandr-shared"
}

locals {
  # This stack's identity. Everything below derives from these — the
  # provider, resource names, ARNs — so onboarding a region is a copy of
  # this file with the three edited.
  env        = "production"
  region     = "us-east-1"
  account_id = "393686273464"

  # Is this the env's PRIMARY region? The archive is written by BE from
  # Postgres, which is central, so there is ONE archive per env and it
  # lives here. Secondary regions are mcp-only: they get a payloads
  # bucket — which IS per region, because the proxy writes it on the hot
  # path — and no archive.
  #
  # Deliberately NOT derived from whether the api module is present.
  # Production creates the archive bucket ahead of its deferred workload
  # to reserve the global S3 name, and development has no ECS at all yet
  # still writes an archive from a laptop.
  #
  # S3 catches half a mistake: `meandr-mcp-archive-<env>` is globally
  # unique, so a second region trying to create it fails loudly. The Glue
  # database would NOT — catalogs are per region, so a duplicate would
  # silently stand up an empty database whose queries return nothing.
  primary = true

  tags = {
    "meandr:env"        = local.env
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# --- Capture buckets ----------------------------------------------------
#
# NOT deferred, unlike the rest of production.
#
# S3's namespace is GLOBAL — a bucket name is claimable by any AWS
# account on earth until we hold it — so these are created ahead of the
# workload purely to reserve the names. An empty bucket bills nothing;
# the only cost is the CMK below, at roughly $1/month, which production
# needs eventually anyway.
#
# The payload CMK is lifted out with them because the buckets encrypt
# with it. multi_region = true is set at creation deliberately: the flag
# is immutable, and production goes multi-region.
#
# The task-role grant (capture_enabled + the two ARNs) goes in when the
# mcp module below is uncommented; until then nothing writes here.

module "archive_bucket" {
  source = "../../modules/s3-capture-bucket"
  count  = local.primary ? 1 : 0

  name        = "meandr-mcp-archive-${local.env}"
  kms_key_arn = module.payload_encryption_key.key_arn
  tags        = local.tags

  # Athena drops query results here and never cleans up.
  prefix_expirations = { "athena-results/" = 1 }
}

module "payloads_bucket" {
  source = "../../modules/s3-capture-bucket"

  name        = "meandr-mcp-payloads-${local.region}-${local.env}"
  kms_key_arn = module.payload_encryption_key.key_arn
  tags        = local.tags
}

module "payload_encryption_key" {
  source = "../../modules/payload-encryption-key"

  env        = local.env
  alias_name = "meandr-payload-${local.env}"

  # BUCKET-AT-REST ONLY, and regional on purpose. Each region encrypts
  # only objects it reads itself, and S3 replication decrypts with the
  # source key and re-encrypts with the destination's, so no payload
  # ciphertext ever needs one key to span regions.
  #
  # Regional is the GUARDRAIL, not merely the cheaper default. A key that
  # cannot be replicated cannot be quietly adopted for something that
  # crosses regions — that misuse would work in one region and fail in the
  # next, which is the hardest shape of bug to find. Immutability is doing
  # useful work here: keep it.
  #
  # The envelope key (elicitation forms) is the one that crosses and must
  # be multi-region. Staging has it as `action_encryption_key`; production
  # gains it when this region is rebuilt from staging.
  multi_region = false

  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = local.tags
}

/* WORKLOAD-DEFERRED START — modules wrapped until first-deploy day; see header.

# --- VPC ---------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  cidr_block        = "10.20.0.0/16"
  azs               = ["${local.region}a", "${local.region}b"]
  enable_nat        = true
  internal_dns_zone = "${local.env}.meandr.internal"

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

  engine_version = "9.1"
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

  # Secondary regions declare themselves — see the module.
  pitr_enabled                = true
  deletion_protection_enabled = true

  tags = local.tags
}

module "cred_encryption_key" {
  source = "../../modules/cred-encryption-key"

  env        = local.env
  alias_name = "meandr-cred-${local.env}"

  # Multi-region from day one — production will expand beyond us-east-1
  # over time; multi_region is IMMUTABLE after key creation so we must
  # set it correctly on first apply. Replicas in other regions are
  # provisioned separately (aws_kms_replica_key) when those regions
  # come online; this primary can then be decrypted from any replica
  # region without cross-region API calls at Decrypt time.
  multi_region = true

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

  # OAuth 2.1 issuer host — see meandr-mcp's oauth_issuer_host.
  extra_hostnames = ["mcp.meandr.com"]

  # ACME DNS-01 into meandr.io, whose zone lives in Shared. Created by
  # shared/acme.tf (apply that first); hardcoded rather than remote-state
  # read to keep this stack's only cross-account dependency the provider
  # alias. `terraform -chdir=shared output acme_dns_role_arns`.
  acme_dns_role_arn = "arn:aws:iam::303529433558:role/meandr-acme-dns-production"

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

# --- Outputs (live) -----------------------------------------------------
#
# Only what is actually deployed. The rest sits in the deferred block
# below and comes back with the workload — same list as staging, minus
# what production does not run yet.

output "archive_bucket" {
  description = "Calls + actions Parquet. The only bucket Athena scans."
  value       = one(module.archive_bucket[*].bucket)
}

output "payloads_bucket" {
  description = "Request/response bodies. Written by the proxy, read by ranged GET; never scanned."
  value       = module.payloads_bucket.bucket
}

output "payload_encryption_key_alias" {
  description = "Payload KMS alias (full form, including `alias/`). SSE-KMS for both buckets, and the approval-flow envelope key once the workload lands."
  value       = module.payload_encryption_key.alias_name
}

output "payload_encryption_key_arn" {
  description = "Payload KMS CMK ARN."
  value       = module.payload_encryption_key.key_arn
}

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

WORKLOAD-DEFERRED END (outputs) */

