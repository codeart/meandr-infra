# staging / eu-central-1 — explicit module list. Onboarding a new region =
# copy this file, change identity vars (env, account, CIDR, hostname) +
# uncomment/comment module blocks per which apps run there.

provider "aws" {
  region  = local.region
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
  # This stack's identity. Everything below derives from these — the
  # provider, resource names, ARNs — so onboarding a region is a copy of
  # this file with the three edited.
  env        = "staging"
  region     = "eu-central-1"
  account_id = "259534890849"

  # Source-built, not packaged. AL2023 carries valkey 8.0.1/8.0.2/8.0.3 and
  # nothing newer (verified 2026-08-23 against the aarch64 repo), while
  # hash-field TTLs — HEXPIRE, which the event tier's rate-limit windows
  # depend on — landed in 9.x. Redis is not the escape hatch: redis.io
  # publishes no aarch64 RPMs for RHEL9, so on Graviton both forks require
  # a build either way, and only one of them is BSD-3.
  #
  # Upgrade order is replicas first, master last: a replica newer than its
  # master is safe, the reverse is not.
  valkey_version = "9.1.1"

  # The vendored source, and its digest computed from the file itself —
  # nothing to publish by hand and no digest to remember on a version bump.
  # A version with no vendored tarball fails at plan.
  valkey_source_path = "${path.root}/../../modules/valkey-node/vendor/valkey-${local.valkey_version}.tar.gz"

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

# --- VPC ---------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  cidr_block        = "10.10.0.0/16"
  azs               = ["${local.region}a", "${local.region}b"]
  enable_nat        = true
  internal_dns_zone = "${local.env}.meandr.internal"

  tags = local.tags
}

# --- Credential store (Dynamo + KMS envelope) --------------------------
#
# BE writes AES-256-GCM-encrypted server creds to the cred Dynamo table
# alongside the cred_version + key_version metadata; proxy reads on
# cfg.server events and decrypts locally with a KMS-wrapped data key
# fetched from SM. See docs/credential_store.md for the full Ruby↔Go
# wire contract.
#
# Staging is single-region — no replica_regions on the table. When
# production launches a secondary proxy region, that caller adds the
# region to `replica_regions` and a Global Tables replica spins up.

module "creds_table" {
  source = "../../modules/dynamodb-creds-table"

  name = "meandr-creds-${local.env}"

  pitr_enabled                = false # staging: throwaway data, no audit need
  deletion_protection_enabled = false # staging: easy teardown

  tags = local.tags
}

module "cred_encryption_key" {
  source = "../../modules/cred-encryption-key"

  env        = local.env
  alias_name = "meandr-cred-${local.env}"

  # Annual auto-rotation on. Dated SM secrets (per data key) live under
  # meandr/mcp/staging/key/<date> and are managed by the BE bootstrap +
  # rotation tasks — not in TF.
  enable_key_rotation     = true
  deletion_window_in_days = 7 # staging: short window for easy iteration

  # Staging is intentionally single-region (eu-central-1 only).
  # multi_region defaults to false; explicit here for clarity.
  #
  # TODO(staging-reset): flip to `true` during the planned staging
  # reset (migration consolidation + test-data wipe). multi_region is
  # IMMUTABLE, and the reset destroys the CMK anyway — the natural
  # moment to correct this without a data migration. Costs the same
  # as single-region until we actually add replicas.
  multi_region = false

  tags = local.tags
}

module "payload_encryption_key" {
  source = "../../modules/payload-encryption-key"

  env        = local.env
  alias_name = "meandr-payload-${local.env}"

  enable_key_rotation     = true
  deletion_window_in_days = 7 # staging: short window for easy iteration

  # Staging single-region. Production is multi_region=true (planned
  # multi-region rollout).
  #
  # TODO(staging-reset): same rationale as cred_encryption_key above —
  # flip to `true` during the planned staging reset.
  multi_region = false

  tags = local.tags
}

# --- Redis AUTH token (shared across all three planes) -----------------
#
# One token per env, used by config-stream + event-stream + api-redis.
# Network isolation (private subnets + SG ingress) stays the primary
# trust boundary; AUTH is defense-in-depth and helps with SOC 2 / HIPAA
# questionnaires that ask specifically about data-tier auth.
#
# Rollout sequence on a cluster that's already running without AUTH:
#   1. First apply with `auth_token_update_strategy = "ROTATE"` (the
#      default in the elasticache-valkey module) — cluster starts
#      accepting both no-auth and the new token. Apps can roll their
#      task defs onto the new password env vars during this window
#      without disconnects.
#   2. Second apply with no changes (still ROTATE) — cluster has been
#      auth-only since the first apply finished propagating, but a
#      no-op second apply makes the state explicit.
# To rotate later: change the random_password length/keepers, apply.

resource "random_password" "redis_auth" {
  length  = 64
  special = false # ElastiCache AUTH tokens allow printable ASCII; staying alphanumeric avoids URL-encoding traps in BE / proxy code.
}

resource "aws_secretsmanager_secret" "redis_auth" {
  name        = "meandr/redis/${local.env}/auth-token"
  description = "Shared Redis AUTH token — config-stream + event-stream + api-redis."
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id     = aws_secretsmanager_secret.redis_auth.id
  secret_string = random_password.redis_auth.result
}

# --- Proxy client-session JWT signing key ------------------------------
#
# Signs the Mcp-Session-Id JWT (HS256, symmetric). Every proxy task in
# the env fleet must verify with the same key; rotating means bumping
# random_password.session_signing_key.keepers so a new random is
# generated + re-applied. Rotation invalidates existing JWTs → clients
# re-initialize on their next call (spec-compliant 404 flow). 64 bytes
# is plenty for HS256 (needs ≥32).
resource "random_password" "session_signing_key" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "session_signing_key" {
  name        = "meandr/session/${local.env}/signing-key"
  description = "HS256 key signing client-session JWTs (Mcp-Session-Id) on the proxy."
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "session_signing_key" {
  secret_id     = aws_secretsmanager_secret.session_signing_key.id
  secret_string = random_password.session_signing_key.result
}

# --- Config-stream Valkey ----------------------------------------------
#
# The shared Redis where the BE writes config records (projects, servers,
# agents, policies, tokens, hosts, tools) and produces the inbound event
# stream that the proxy consumes. Lives at region level (not inside an
# app module) because both meandr-api and meandr-mcp consume it.
# Standalone today; promotes to gd_primary when production launches a
# second region. TLS-on from day 1 — required for Global Datastore
# eligibility, can't be toggled in place.

module "config_stream" {
  source = "../../modules/elasticache-valkey"

  name        = "meandr-config-stream"
  description = "Config-stream Valkey staging - BE writes config + inbound events, proxy reads config + consumes inbound events"

  engine_version = "9.1"
  node_type      = "cache.t4g.micro"

  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  auth_token = random_password.redis_auth.result

  snapshot_retention_days = 1

  vpc_id             = module.vpc.vpc_id
  vpc_cidr_block     = module.vpc.vpc_cidr_block
  private_subnet_ids = module.vpc.private_subnet_ids

  tags = merge(local.tags, { "meandr:plane" = "config" })
}

# Local-module rename in state. The AWS replication_group_id also changes
# (`meandr-reader` → `meandr-config-stream`), so the underlying cluster
# gets destroyed and recreated — `moved` here just keeps the state-tree
# addressing consistent across the rename.
moved {
  from = module.config_valkey
  to   = module.config_stream
}

# --- Self-hosted Valkey (config tier) -----------------------------------
#
# Runs ALONGSIDE config_stream, not instead of it. Nothing points at these
# nodes yet: the proxy cannot verify our CA until internal/rdb learns to
# take a RootCAs bundle, so this stands the fleet up to be watched —
# replication, a deliberate failover — while the live path is untouched.
# Cutover is a separate, reversible change once both sides are ready.

# How vendored source reaches an instance. User-data caps at 16 KB and the
# Valkey tarball is megabytes, so it cannot ride inline; this is the
# transport.
#
# In THIS account and region on purpose. A gateway endpoint only routes to
# the regional S3 service, so a bucket anywhere else would mean NAT egress
# on every boot — putting the internet back on the path we vendored the
# source to keep it off. Re-uploading 4 MB per environment is the cheaper
# side of that trade.
#
# Not the capture or payloads buckets: those hold customer data under a
# retention policy, and a blob read by an instance role at boot has no
# business sharing either.
resource "aws_s3_bucket" "artifacts" {
  bucket = "meandr-artifacts-${local.env}-${local.region}"
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioned so that overwriting a key cannot destroy the source a running
# node would fetch if it were replaced today.
resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# The vendored Valkey source, uploaded by the same apply that creates the
# nodes — so a node can never boot against a version that was never
# published. source_hash re-uploads when the vendored file changes; without
# it Terraform compares only metadata and a re-vendored tarball would sit
# in the repo while the old bytes stayed in the bucket.
resource "aws_s3_object" "valkey_source" {
  bucket      = aws_s3_bucket.artifacts.id
  key         = "valkey/${local.valkey_version}/valkey-src.tar.gz"
  source      = local.valkey_source_path
  source_hash = filemd5(local.valkey_source_path)

  tags = local.tags
}

# Capacity reservations for both Valkey fleets — config and events, one
# master and one replica per AZ.
#
# Billed at the on-demand rate whether occupied or not, so for nodes that
# run continuously this is not extra cost. It guarantees the slot across
# the instance replacement that every user-data change triggers.
#
# "open" match: any t4g.micro launched in the AZ uses it, no per-instance
# wiring.
resource "aws_ec2_capacity_reservation" "valkey" {
  for_each = toset(["${local.region}a", "${local.region}b"])

  instance_type           = "t4g.micro"
  instance_platform       = "Linux/UNIX"
  availability_zone       = each.value
  instance_count          = 2
  end_date_type           = "unlimited"
  instance_match_criteria = "open"

  tags = merge(local.tags, { Name = "valkey-${each.value}" })
}

module "valkey_tls" {
  source = "../../modules/valkey-tls"

  env           = local.env
  dns_zone_name = module.vpc.internal_dns_zone_name

  # No replicas yet — one region. Add the second region here when it lands,
  # or its nodes cannot read the secret at all.
  replica_regions = []

  tags = local.tags
}

module "valkey_config_a" {
  source = "../../modules/valkey-node"

  fleet = "config"
  node  = "a"

  # Bootstrap tie-break only — see the module's variable doc. This node may
  # take the master role when no record resolves, which happens exactly
  # once. On every later boot, including its own replacement, the record
  # decides.
  role = "master"

  # Vendor the source BEFORE an apply that changes the version — the node
  # compiles `valkey/<version>/…` from the bucket and aborts user-data if it
  # is missing or the digest does not match.
  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  # Both nodes must match: they swap roles on failover.
  instance_type = "t4g.micro"

  # Fail fast so an outer retry loop drives the cadence, rather than the
  # provider retrying silently for over an hour.
  create_timeout = "2m"

  # Sentinel runs on every node, here and in every later region — confining
  # it to promotable nodes would cap the fleet at two voters forever.
  #
  # Quorum 2 of 2 today means NO automatic failover: an isolated master
  # leaves one voter, which can never agree with itself. Deliberate —
  # quorum 1 across two partitioned Sentinels lets both promote, which is
  # worse than promoting neither. Manual `SENTINEL FAILOVER config` is
  # forced and needs no agreement, so it works meanwhile.
  #
  # SECOND REGION: 4 nodes → 4 Sentinels → quorum 3, set on EVERY node.
  # Sentinel authorises a failover by majority of the whole set whatever
  # quorum says, so 4-with-quorum-3 tolerates one loss — the same as 3
  # would. The even count buys availability, not fault tolerance.
  run_sentinel    = true
  sentinel_quorum = 2

  auth_secret_arn = aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = module.valkey_tls.node_secret_arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[0] # AZ-a

  # The whole VPC for now: ECS tasks and the peer node both live here.
  # Narrows to the task subnets once the client set is settled.
  client_cidrs = [module.vpc.vpc_cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "config" })
}

module "valkey_config_b" {
  source = "../../modules/valkey-node"

  fleet = "config"
  node  = "b"

  # Bootstrap tie-break only: before the master record exists, this node
  # waits rather than racing valkey-a for the role. Afterwards every boot
  # derives its role from the record, so replacing either node is safe
  # regardless of which one is master at the time.
  role = "replica"

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  # Both nodes must match: they swap roles on failover.
  instance_type = "t4g.micro"

  # Fail fast so an outer retry loop drives the cadence, rather than the
  # provider retrying silently for over an hour.
  create_timeout = "2m"

  # Must carry the SAME quorum as every other node — Sentinels that
  # disagree about what agreement means do not agree about anything.
  run_sentinel    = true
  sentinel_quorum = 2

  auth_secret_arn = aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = module.valkey_tls.node_secret_arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[1] # AZ-b — the point of the pair

  client_cidrs = [module.vpc.vpc_cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "config" })
}

# The master record, created ONCE and then left alone.
#
# Terraform has to bootstrap it — Sentinel only writes the record on a
# FAILOVER, so without this the first replica has no master to resolve and
# nothing ever converges. But ownership passes to Sentinel the moment it
# exists: ignore_changes is what stops the next apply from pointing every
# writer back at a node that was demoted hours ago.
resource "aws_route53_record" "valkey_config_master" {
  zone_id = module.vpc.internal_dns_zone_id
  name    = module.valkey_config_a.master_hostname
  type    = "CNAME"
  # 5s: this record follows a failover, so its TTL is how long a client
  # keeps dialling the demoted node.
  ttl     = 5
  records = [module.valkey_config_a.hostname]

  lifecycle {
    ignore_changes = [records]
  }
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

  # OAuth 2.1 issuer host — see meandr-mcp's oauth_issuer_host.
  extra_hostnames = ["staging-mcp.meandr.com"]

  # ACME DNS-01 into meandr.live, whose zone lives in Shared. Created by
  # shared/acme.tf (apply that first); hardcoded rather than remote-state
  # read to keep this stack's only cross-account dependency the provider
  # alias. `terraform -chdir=shared output acme_dns_role_arns`.
  acme_dns_role_arn = "arn:aws:iam::303529433558:role/meandr-acme-dns-staging"

  vpc_id                 = module.vpc.vpc_id
  vpc_cidr_block         = module.vpc.vpc_cidr_block
  public_subnet_ids      = module.vpc.public_subnet_ids
  private_subnet_ids     = module.vpc.private_subnet_ids
  internal_dns_zone_id   = module.vpc.internal_dns_zone_id
  internal_dns_zone_name = module.vpc.internal_dns_zone_name

  config_writer_endpoint          = module.config_stream.primary_endpoint_address
  config_stream_security_group_id = module.config_stream.security_group_id

  # State-plane regions BE should consume streams from. Just our own
  # region today; expand when more regions come online with meandr-mcp.
  # event_writer_endpoints is positional with regions — first region's
  # event-stream writer, second region's, etc. In a multi-region prod
  # setup the extra regions' endpoints come via terraform_remote_state.
  regions                = [local.region]
  event_writer_endpoints = [module.mcp.event_writer_endpoint]

  redis_auth_token      = random_password.redis_auth.result
  redis_auth_secret_arn = aws_secretsmanager_secret.redis_auth.arn

  cred_store_enabled        = true
  creds_table_name          = module.creds_table.table_name
  creds_table_arn           = module.creds_table.table_arn
  cred_encryption_key_arn   = module.cred_encryption_key.key_arn
  cred_encryption_key_alias = module.cred_encryption_key.alias_name

  db_instance_class = "db.t4g.micro"
  puma              = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 70, concurrency : 0, threads : 6 }
  jobs              = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 70 }
  ingest            = { cpu = 256, memory = 512, desired_count = 1 }
  migrate           = { cpu = 512, memory = 1024 }

  log_retention_days = 7

  # BE writes the archive (daily Parquet) and READS + RETAGS payloads —
  # never writes bodies. Retag is the cancellation flow: move an
  # account's objects from `inf` to `1d` and let the bucket's lifecycle
  # do the deleting.
  capture_enabled            = true
  archive_bucket_arn         = one(module.archive_bucket[*].arn)
  payloads_bucket_arn        = module.payloads_bucket.arn
  payload_encryption_key_arn = module.payload_encryption_key.key_arn
}

# --- meandr-mcp --------------------------------------------------------
#
# Proxy stack: writer Valkey + NLB + ECS cluster + proxy service. NLB has
# two plain TCP listeners (80 + 443) forwarding to proxy:8080; proxy
# terminates TLS itself once the BE-side cert pipeline lands (Phase 2).
# Customer HTTPS traffic won't work end-to-end until then — expected v0.

# --- Capture buckets ----------------------------------------------------
#
# Split by who writes and how it is read (capture_and_archive.md §6):
# archive is BE-written Parquet queried by Athena, so ONE per env and
# single-region; payloads are proxy-written bodies, regional because the
# proxy writes them on the hot path, and never scanned — a ref names the
# bucket and a byte range.

module "archive_bucket" {
  source = "../../modules/s3-capture-bucket"
  count  = local.primary ? 1 : 0

  name        = "meandr-mcp-archive-${local.env}"
  kms_key_arn = module.payload_encryption_key.key_arn
  tags        = local.tags

  # Athena drops query results here and never cleans up.
  prefix_expirations = { "athena-results/" = 1 }
}

module "archive_database" {
  source = "../../modules/glue-database"
  count  = local.primary ? 1 : 0

  name        = "meandr_${local.env}"
  description = "meandr archive (${local.env}) — external tables over ${one(module.archive_bucket[*].bucket)}"
  tags        = local.tags
}

module "payloads_bucket" {
  source = "../../modules/s3-capture-bucket"

  name        = "meandr-mcp-payloads-${local.region}-${local.env}"
  kms_key_arn = module.payload_encryption_key.key_arn
  tags        = local.tags
}

module "mcp" {
  source = "../../modules/meandr-mcp"

  providers = {
    aws     = aws
    aws.dns = aws.shared
  }

  env        = local.env
  account_id = local.account_id

  image_tag = "develop"

  vpc_id                 = module.vpc.vpc_id
  vpc_cidr_block         = module.vpc.vpc_cidr_block
  public_subnet_ids      = module.vpc.public_subnet_ids
  private_subnet_ids     = module.vpc.private_subnet_ids
  internal_dns_zone_id   = module.vpc.internal_dns_zone_id
  internal_dns_zone_name = module.vpc.internal_dns_zone_name

  config_reader_endpoint = module.config_stream.reader_endpoint_address

  redis_auth_enabled    = true
  redis_auth_token      = random_password.redis_auth.result
  redis_auth_secret_arn = aws_secretsmanager_secret.redis_auth.arn

  session_signing_key_secret_arn = aws_secretsmanager_secret.session_signing_key.arn

  cred_store_enabled      = true
  creds_table_name        = module.creds_table.table_name
  creds_table_arn         = module.creds_table.table_arn
  cred_encryption_key_arn = module.cred_encryption_key.key_arn

  # On ahead of the writer. The grant and the env var are inert until
  # the proxy has capture code — nothing reads MEANDR_CAPTURE_BUCKET yet
  # — but wiring them now means the writer ships without a second task
  # definition revision and a second rolling restart.
  capture_enabled              = true
  payloads_bucket              = module.payloads_bucket.bucket
  payloads_bucket_arn          = module.payloads_bucket.arn
  payload_encryption_key_arn   = module.payload_encryption_key.key_arn
  payload_encryption_key_alias = module.payload_encryption_key.alias_name

  # Staging customer-facing MCP traffic lands at *.meandr.live. Production
  # uses the module default *.meandr.io. The split keeps staging traffic
  # off the production-shaped hostname and lets us roll DNS / certs on
  # meandr.live without touching production's apex.
  dns_zone_name = "meandr.live"

  # The authorization server lives on BE's zone, not the tenant wildcard
  # above — see the module's oauth_issuer_host. Kept dark until the record
  # resolves and BE answers on it; flipping the flag is the whole switch.
  oauth_issuer_host       = "staging-mcp.meandr.com"
  oauth_discovery_enabled = true

  event_stream_node_type = "cache.t4g.micro"
  proxy                  = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 60 }

  log_retention_days = 7
}

# --- Outputs -----------------------------------------------------------

output "vpc_id" { value = module.vpc.vpc_id }
output "vpc_cidr_block" { value = module.vpc.vpc_cidr_block }
output "public_subnet_ids" { value = module.vpc.public_subnet_ids }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }

output "config_stream_writer_endpoint" { value = module.config_stream.primary_endpoint_address }
output "config_stream_reader_endpoint" { value = module.config_stream.reader_endpoint_address }
output "event_stream_writer_endpoint" { value = module.mcp.event_writer_endpoint }

output "hostname" { value = module.api.hostname }
output "alb_dns_name" { value = module.api.alb_dns_name }
output "cluster_name" { value = module.api.cluster_name }
output "puma_service_name" { value = module.api.puma_service_name }
output "jobs_service_name" { value = module.api.jobs_service_name }
output "ingest_service_name" { value = module.api.ingest_service_name }
output "migrate_task_family" { value = module.api.migrate_task_family }
output "worker_sg_id" { value = module.api.worker_security_group_id }
output "rds_internal_dns_name" { value = module.api.rds_internal_dns_name }

output "mcp_cluster_name" { value = module.mcp.cluster_name }
output "mcp_proxy_service_name" { value = module.mcp.proxy_service_name }
output "mcp_nlb_dns_name" { value = module.mcp.nlb_dns_name }

output "archive_bucket" {
  description = "Calls + actions Parquet. The only bucket Athena scans."
  value       = one(module.archive_bucket[*].bucket)
}

output "payloads_bucket" {
  description = "Request/response bodies. Written by the proxy, read by ranged GET; never scanned."
  value       = module.payloads_bucket.bucket
}
