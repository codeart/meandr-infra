# staging / eu-central-1 — explicit module list. Onboarding a new region =
# copy this file, change identity vars (env, account, CIDR, hostname) +
# uncomment/comment module blocks per which apps run there.

provider "aws" {
  region  = local.region
  profile = local.aws_profile
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

  # Named here because recipes run SSM calls from the OPERATOR's machine,
  # where there is no provider to inherit credentials from.
  aws_profile = "meandr-staging"

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

  # A literal, not the bucket's id: the node module gates its backup IAM on
  # a count, and count must be knowable at plan time.
  valkey_backup_bucket = "meandr-valkey-backups-${local.env}-${local.region}"

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

# Applications run in a and b ONLY. Zone c exists for the Sentinel arbiter,
# so that losing a zone never costs two of three votes — putting a third
# Sentinel in a zone that already holds one would defeat the purpose.
#
# Everything that takes a whole subnet list gets these, not the module's
# outputs: an ALB or ECS service handed three subnets would spread into c
# and quietly make it a third app zone.
locals {
  app_public_subnet_ids  = slice(module.vpc.public_subnet_ids, 0, 2)
  app_private_subnet_ids = slice(module.vpc.private_subnet_ids, 0, 2)
}

# --- VPC ---------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  cidr_block = "10.10.0.0/16"
  # APPEND only. Subnet ids are output in this order and callers index them
  # positionally, so inserting an AZ would move existing nodes.
  azs               = ["${local.region}a", "${local.region}b", "${local.region}c"]
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

# --- Self-hosted Valkey (config tier) -----------------------------------
#
# Replaced the `config_stream` ElastiCache cluster, removed 2026-08-25
# once both sides had cut over — verified zero commands across every
# metric type before deletion, not merely zero connections, which never
# reaches zero while ElastiCache health-checks itself.
#
# Both the proxy and BE reach these through Sentinel over mTLS. See
# docs/valkey_fleets.md.

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

# Capacity for every Valkey node in the region: three per AZ — the config,
# events and api members in a and b, the three arbiters in c. Nine slots.
#
# One resource rather than one per fleet because a reservation matches on
# type and zone, not on purpose. Every node is a t4g.nano, so a single pool
# per AZ covers whichever of them lands there.
#
# Billed at the on-demand rate whether occupied or not, so for nodes that
# run continuously this is not extra cost. It guarantees the slot across
# the instance replacement that every user-data change triggers.
#
# "open" match: any t4g.nano launched in the AZ uses it, with no
# per-instance wiring. Nothing binds an instance to a reservation, so the
# only thing that makes one count is existing BEFORE the launch — apply it
# first and on its own:
#
#   terraform apply -target=aws_ec2_capacity_reservation.valkey_nano
#
# NOT with depends_on on the valkey modules. A module-level depends_on
# defers every data source inside it, which makes local.user_data unknown
# at plan time; user_data_replace_on_change can only compare known values,
# so it silently stops firing and a user-data change plans as an in-place
# update. User-data runs once per instance, so that update would never
# take effect — the node keeps its old config and nothing says so.
#
# eu-central-1c ran dry of t4g.nano for hours on 2026-08-25.
resource "aws_ec2_capacity_reservation" "valkey_nano" {
  for_each = toset(["${local.region}a", "${local.region}b", "${local.region}c"])

  instance_type           = "t4g.nano"
  instance_platform       = "Linux/UNIX"
  availability_zone       = each.value
  instance_count          = 3
  end_date_type           = "unlimited"
  instance_match_criteria = "open"

  tags = merge(local.tags, { Name = "valkey-nano-${each.value}" })
}


# RDB backups, written by whichever node is currently the replica.
#
# Lifecycle rather than versioning: keys are timestamped and never
# overwritten, so there is nothing to version — only to expire.
resource "aws_s3_bucket" "valkey_backups" {
  bucket = local.valkey_backup_bucket
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "valkey_backups" {
  bucket = aws_s3_bucket.valkey_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "valkey_backups" {
  bucket = aws_s3_bucket.valkey_backups.id

  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration { days = 30 }
  }
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
  node  = "euc1a"

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
  instance_type     = "t4g.nano"
  maxmemory_percent = 50 # nano: 512 MiB total, the OS takes ~250 of them

  backup_bucket = local.valkey_backup_bucket

  # Fail fast so an outer retry loop drives the cadence, rather than the
  # provider retrying silently for over an hour.
  create_timeout = "2m"

  # Sentinel runs on every node, here and in every later region — confining
  # it to promotable nodes would cap the fleet at two voters forever.
  #
  # Quorum 2 of 3, counting the AZ-c arbiter: automatic failover now
  # survives the loss of any one zone. Sentinel authorises by MAJORITY OF
  # THE WHOLE SET whatever quorum says, which is why a third voter — not a
  # lower quorum — is what fixed it. Quorum 1 across a partition would let
  # both sides promote, which is worse than promoting neither.
  #
  # SECOND REGION: 4 Sentinels → quorum 3, set on EVERY node. Still one
  # tolerated loss, same as 3 — the even count buys availability, not fault
  # tolerance.
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
  node  = "euc1b"

  # Bootstrap tie-break only: before the master record exists, this node
  # waits rather than racing valkey-a for the role. Afterwards every boot
  # derives its role from the record, so replacing either node is safe
  # regardless of which one is master at the time.
  role = "replica"

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  # Both nodes must match: they swap roles on failover.
  instance_type     = "t4g.nano"
  maxmemory_percent = 50 # nano: 512 MiB total, the OS takes ~250 of them

  backup_bucket = local.valkey_backup_bucket

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

# --- Self-hosted Valkey (events tier) -----------------------------------
#
# The proxy→BE bus: proxy writes events, BE reads them. Per region and
# NEVER replicated across regions — an event belongs to the region that
# produced it, and shipping the stream transatlantically would put write
# volume on a link the config tier needs for reads.
#
# Its own fleet rather than a database on the config nodes: the profiles
# are opposites. Config is read-heavy with a small projection; events are
# write-heavy and carry the rate-limit hashes whose per-field TTLs are why
# the whole fleet runs 9.x.
#
# Shares the CA, the vendored source and the capacity reservations with
# the config tier. Everything else — subdomain, master record, Sentinel
# group — is fleet-scoped and therefore separate by construction.

module "valkey_events_a" {
  source = "../../modules/valkey-node"

  fleet = "events"
  node  = "euc1a"
  role  = "master"

  # Region-qualified: events is one fleet PER REGION, and the DNS zone is
  # shared across regions. The derived `events-master` would name a
  # different node in every region while resolving to whichever one wrote
  # it last. `config` needs no such label — it has one master globally,
  # which is the whole point of that fleet.
  master_record_label = "events-master-euc1"

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  instance_type        = "t4g.nano"
  maxmemory_percent    = 50 # nano: 512 MiB total, the OS takes ~250 of them
  create_timeout       = "2m"

  backup_bucket = local.valkey_backup_bucket

  run_sentinel    = true
  sentinel_quorum = 2

  auth_secret_arn = aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = module.valkey_tls.node_secret_arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[0] # AZ-a

  client_cidrs = [module.vpc.vpc_cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "events" })
}

module "valkey_events_b" {
  source = "../../modules/valkey-node"

  fleet = "events"
  node  = "euc1b"
  role  = "replica"

  master_record_label = "events-master-euc1"

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  instance_type        = "t4g.nano"
  maxmemory_percent    = 50 # nano: 512 MiB total, the OS takes ~250 of them
  create_timeout       = "2m"

  backup_bucket = local.valkey_backup_bucket

  run_sentinel    = true
  sentinel_quorum = 2

  auth_secret_arn = aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = module.valkey_tls.node_secret_arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[1] # AZ-b

  client_cidrs = [module.vpc.vpc_cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "events" })
}

resource "aws_route53_record" "valkey_events_master" {
  zone_id = module.vpc.internal_dns_zone_id
  name    = module.valkey_events_a.master_hostname
  type    = "CNAME"
  ttl     = 5
  records = [module.valkey_events_a.hostname]

  lifecycle {
    ignore_changes = [records]
  }
}

# --- Self-hosted Valkey (api tier) --------------------------------------
#
# Rails-owned: ActionCable pub/sub, and cache later. allkeys-lru because
# dropping the coldest key IS the behaviour here — the opposite of the
# other two fleets, where the eventbus refuses to start against anything
# but noeviction.
#
# Gains a replica and failover, which the ElastiCache instance it replaces
# does not have (num_cache_clusters = 1, automatic_failover disabled).

module "valkey_api_a" {
  source = "../../modules/valkey-node"

  fleet = "api"
  node  = "euc1a"
  role  = "master"

  maxmemory_policy  = "allkeys-lru"
  maxmemory_percent = 50

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  instance_type        = "t4g.nano"
  create_timeout       = "2m"

  run_sentinel    = true
  sentinel_quorum = 2

  auth_secret_arn = aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = module.valkey_tls.node_secret_arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[0] # AZ-a

  client_cidrs = [module.vpc.vpc_cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "api" })
}

module "valkey_api_b" {
  source = "../../modules/valkey-node"

  fleet = "api"
  node  = "euc1b"
  role  = "replica"

  maxmemory_policy  = "allkeys-lru"
  maxmemory_percent = 50

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  instance_type        = "t4g.nano"
  create_timeout       = "2m"

  run_sentinel    = true
  sentinel_quorum = 2

  auth_secret_arn = aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = module.valkey_tls.node_secret_arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[1] # AZ-b

  client_cidrs = [module.vpc.vpc_cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "api" })
}

resource "aws_route53_record" "valkey_api_master" {
  zone_id = module.vpc.internal_dns_zone_id
  name    = module.valkey_api_a.master_hostname
  type    = "CNAME"
  ttl     = 5
  records = [module.valkey_api_a.hostname]

  lifecycle {
    ignore_changes = [records]
  }
}

# --- Sentinel arbiters (AZ-c) -------------------------------------------
#
# One per fleet, and the reason is arithmetic: Sentinel authorises a
# failover by MAJORITY OF THE WHOLE SET, not by the quorum setting. Two
# Sentinels have a majority of two, so losing either one left the fleet
# with no automatic failover at all — the pair could detect a dead master
# and still be unable to replace it.
#
# A third vote in a third zone makes the majority reachable after any
# single-AZ loss. Quorum stays 2 precisely because it was already right;
# what changes is how many Sentinels survive to reach it.
#
# `sentinel_only` means no valkey-server: these hold no data, take no
# backups, run no metrics timer, and are never a promotion target. A nano
# is sufficient for a fleet of any size, which is why the third zone costs
# three small instances rather than three more replicas.
#
# AZ-c deliberately holds nothing else. Apps stay in a and b; this zone
# exists so a zone failure cannot take two of three votes with it.

module "valkey_config_c" {
  source = "../../modules/valkey-node"

  fleet = "config"
  node  = "euc1c"

  # Bootstrap tie-break only, and for an arbiter it can only ever mean
  # "wait" — there is no server here to promote.
  role = "replica"

  sentinel_only = true
  run_sentinel  = true
  # Unchanged from the pair: three Sentinels, majority still 2.
  sentinel_quorum = 2

  # Inert while sentinel_only holds — carried so clearing that flag yields
  # a node sized like its fleet, not one on the 70% default a nano cannot
  # afford.
  maxmemory_percent = 50

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  instance_type        = "t4g.nano"
  create_timeout       = "2m"

  auth_secret_arn = aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = module.valkey_tls.node_secret_arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[2] # AZ-c — the third zone IS the point

  client_cidrs = [module.vpc.vpc_cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "config" })
}

module "valkey_events_c" {
  source = "../../modules/valkey-node"

  fleet = "events"
  node  = "euc1c"
  role  = "replica"

  master_record_label = "events-master-euc1"

  sentinel_only   = true
  run_sentinel    = true
  sentinel_quorum = 2

  # Inert while sentinel_only holds — see valkey_config_c.
  maxmemory_percent = 50

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  instance_type        = "t4g.nano"
  create_timeout       = "2m"

  auth_secret_arn = aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = module.valkey_tls.node_secret_arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[2] # AZ-c

  client_cidrs = [module.vpc.vpc_cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "events" })
}

module "valkey_api_c" {
  source = "../../modules/valkey-node"

  fleet = "api"
  node  = "euc1c"
  role  = "replica"

  sentinel_only   = true
  run_sentinel    = true
  sentinel_quorum = 2

  # Inert while sentinel_only holds — carried so that clearing that flag
  # yields a node matching its fleet rather than one silently on the
  # noeviction default.
  maxmemory_policy  = "allkeys-lru"
  maxmemory_percent = 50

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  instance_type        = "t4g.nano"
  create_timeout       = "2m"

  auth_secret_arn = aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = module.valkey_tls.node_secret_arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[2] # AZ-c

  client_cidrs = [module.vpc.vpc_cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "api" })
}

# --- Valkey recipes ----------------------------------------------------
#
# Ordered, once-per-node changes applied to RUNNING instances over SSM.
#
# The counterpart to user-data, not a replacement for it: anything
# identity-level or restart-required stays in user-data and is worth the
# instance replacement. Everything else — a logrotate file, a sysctl, a
# unit tweak — lands here and costs nothing.
#
# Adding a recipe can never produce a plan that rebuilds the fleet,
# because recipes are never embedded in user-data.

module "valkey_recipes" {
  source = "../../modules/valkey-recipes"

  instance_ids = [
    module.valkey_config_a.instance_id,
    module.valkey_config_b.instance_id,
    module.valkey_config_c.instance_id,
    module.valkey_events_a.instance_id,
    module.valkey_events_b.instance_id,
    module.valkey_events_c.instance_id,
    module.valkey_api_a.instance_id,
    module.valkey_api_b.instance_id,
    module.valkey_api_c.instance_id,
  ]

  aws_profile = local.aws_profile
  aws_region  = local.region
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
  public_subnet_ids      = local.app_public_subnet_ids
  private_subnet_ids     = local.app_private_subnet_ids
  internal_dns_zone_id   = module.vpc.internal_dns_zone_id
  internal_dns_zone_name = module.vpc.internal_dns_zone_name

  # State-plane regions BE consumes streams from. Just our own region
  # today; expand when more come online with meandr-mcp. In a multi-region
  # production setup the extra regions' groups arrive via
  # terraform_remote_state.
  regions = [local.region]

  # BE reaches every fleet through Sentinel — no URL fallback, because a
  # URL cannot carry a client certificate and the fleets refuse a
  # connection without one.
  #
  # EVERY region's event group, unlike the proxy which only needs its
  # own: BE consumes every region's stream. Positional with `regions`.
  config_sentinel_addrs = [
    "${module.valkey_config_a.hostname}:26379",
    "${module.valkey_config_b.hostname}:26379",
    "${module.valkey_config_c.hostname}:26379",
  ]
  config_sentinel_master = "config"

  event_sentinel_groups = [join(",", [
    "${module.valkey_events_a.hostname}:26379",
    "${module.valkey_events_b.hostname}:26379",
    "${module.valkey_events_c.hostname}:26379",
  ])]
  event_sentinel_master = "events"

  api_sentinel_addrs = [
    "${module.valkey_api_a.hostname}:26379",
    "${module.valkey_api_b.hostname}:26379",
    "${module.valkey_api_c.hostname}:26379",
  ]
  api_sentinel_master = "api"

  valkey_client_secret_arn = module.valkey_tls.client_secret_arn

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
  public_subnet_ids      = local.app_public_subnet_ids
  private_subnet_ids     = local.app_private_subnet_ids
  internal_dns_zone_id   = module.vpc.internal_dns_zone_id
  internal_dns_zone_name = module.vpc.internal_dns_zone_name

  # Self-hosted fleets. The ADDRs are bootstrap only — Sentinel is what
  # the client actually follows, so a failover moves it without waiting
  # on a DNS TTL.
  #
  # Local Sentinels by necessity: Sentinel answers with a node HOSTNAME,
  # so another region's set would name something this VPC cannot resolve.
  config_reader_endpoint = module.valkey_config_a.master_hostname
  config_sentinel_addrs = [
    "${module.valkey_config_a.hostname}:26379",
    "${module.valkey_config_b.hostname}:26379",
    "${module.valkey_config_c.hostname}:26379",
  ]
  config_sentinel_master = "config"

  event_writer_endpoint = module.valkey_events_a.master_hostname
  event_sentinel_addrs = [
    "${module.valkey_events_a.hostname}:26379",
    "${module.valkey_events_b.hostname}:26379",
    "${module.valkey_events_c.hostname}:26379",
  ]
  event_sentinel_master = "events"

  # Required to reach either fleet: the nodes run `tls-auth-clients yes`
  # and refuse a connection with no client certificate.
  valkey_client_secret_arn = module.valkey_tls.client_secret_arn

  redis_auth_enabled    = true
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

  proxy = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 60 }

  log_retention_days = 7
}

# --- Outputs -----------------------------------------------------------

output "vpc_id" { value = module.vpc.vpc_id }
output "vpc_cidr_block" { value = module.vpc.vpc_cidr_block }
output "public_subnet_ids" { value = module.vpc.public_subnet_ids }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }

# Master RECORDS, not node names — they follow a promotion. Prefer the
# Sentinel sets for anything that connects; these are for humans and for
# a second region's bootstrap.
output "valkey_config_master" { value = module.valkey_config_a.master_hostname }
output "valkey_events_master" { value = module.valkey_events_a.master_hostname }
output "valkey_api_master" { value = module.valkey_api_a.master_hostname }
output "event_stream_writer_endpoint" { value = module.mcp.event_writer_endpoint }

output "hostname" { value = module.api.hostname }
output "alb_dns_name" { value = module.api.alb_dns_name }
output "cluster_name" { value = module.api.cluster_name }
output "puma_service_name" { value = module.api.puma_service_name }
output "jobs_service_name" { value = module.api.jobs_service_name }
output "ingest_service_name" { value = module.api.ingest_service_name }
output "migrate_task_family" { value = module.api.migrate_task_family }
output "worker_sg_id" { value = module.api.worker_security_group_id }

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
