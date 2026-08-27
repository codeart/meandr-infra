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
  azs        = ["${local.region}a", "${local.region}b", "${local.region}c"]
  enable_nat = true

  # One address, in AZ-a, serving all three zones. AZ-c holds only the
  # Sentinel arbiters, which do not egress at steady state, and AZ-b's
  # workloads can be processed by AZ-a's address — so a second address
  # would be paid for and idle. Production pins two.
  nat_pinned_azs = ["${local.region}a"]

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
# Replication is declared by the edge, not here — see the module. This
# region only makes the table replicable and never names a consumer.

module "creds_table" {
  source = "../../modules/dynamodb-creds-table"

  name = "meandr-creds-${local.env}"

  pitr_enabled                = false # staging: throwaway data, no audit need
  deletion_protection_enabled = false # staging: easy teardown

  # No replica list here. The proxy resolves upstream credentials on the
  # request path, so every region needs this table locally — but an edge
  # declares ITSELF with aws_dynamodb_table_replica in its own state. This
  # region only makes the table replicable (streams), and never learns who
  # took it up.
  tags = local.tags
}

module "cred_encryption_key" {
  source = "../../modules/cred-encryption-key"

  env        = local.env
  alias_name = "meandr-cred-${local.env}"

  # Annual auto-rotation on. There is NO data-key layer and no bootstrap:
  # BE encrypts each cred blob directly with KMS.Encrypt(KeyId=alias), so
  # replacing this key needs nothing seeded — only the existing blobs
  # re-written. See credential_store.md §"terraform apply".
  enable_key_rotation     = true
  deletion_window_in_days = 7 # staging: short window for easy iteration

  # Multi-region, because the cred store is the one dataset that CROSSES
  # regions: BE encrypts a blob once, the Global Table replicates it, and
  # every region's proxy must decrypt that same ciphertext on the request
  # path. Decrypt resolves the key from the blob, and a single-region key
  # simply does not exist at the edge's KMS endpoint.
  #
  # Contrast the payload key, which stays regional — each region encrypts
  # objects only it reads, and S3 replication re-encrypts with the
  # destination's key, so no payload ciphertext ever needs one key to
  # span regions.
  #
  # Replicas are declared by the edge (aws_kms_replica_key), not listed
  # here: this flag makes the key REPLICABLE without naming who takes it
  # up, exactly like the creds table's stream.
  multi_region = true

  tags = local.tags
}

module "payload_encryption_key" {
  source = "../../modules/payload-encryption-key"

  env        = local.env
  alias_name = "meandr-payload-${local.env}"
  purpose    = "SSE-KMS default for the payload + archive buckets"

  enable_key_rotation     = true
  deletion_window_in_days = 7 # staging: short window for easy iteration

  # BUCKET-AT-REST ONLY, and single-region on purpose.
  #
  # S3 replication decrypts with the source key and re-encrypts with the
  # destination's, so a per-region bucket key replicates fine — there is
  # nothing to gain from a multi-region key here, and flipping the flag
  # would recreate the CMK and orphan every payload and archive object
  # already written under it.
  #
  # The application envelope moved to its own key (below), which is what
  # actually needed to exist in more than one region.
  #
  # Regional is also the GUARDRAIL, not merely the cheaper default. A key
  # that cannot be replicated cannot be quietly adopted for something that
  # crosses regions — that misuse would work in one region and fail in the
  # next, which is the hardest shape of bug to find. Immutability is doing
  # useful work here: keep it.
  multi_region = false

  tags = local.tags
}

# The ACTION-form key — payloadcrypt, which wraps the answer to an
# UPSTREAM-initiated elicitation. Separate from the bucket key because the
# two have different geography, not because they hold different secrets.
#
# Only upstream forms are encrypted. Our own approval form rides in
# plaintext on purpose: it is an OTP and a comment, BE must read the OTP to
# validate it, and encrypting it would hand BE kms:Decrypt over every form
# to check a six-digit code. An upstream form can ask for anything — a
# token, a card number — so it must never sit on the event stream in clear.
# See buildResponded in internal/middleware/action_responded.go.
#
# A form is wrapped by whichever region's proxy handled the elicitation and
# unwrapped by BE in the primary region. A region-local key would put a
# transatlantic KMS call on one side or the other; a MULTI-REGION key has a
# replica in each region, so both ends stay local.
#
# Splitting it costs nothing and loses nothing: the bucket key keeps every
# object already written under it, and envelopes record their own CMK
# (payloadcrypt.Envelope.CMK, passed to kms:Decrypt), so envelopes wrapped
# by the older key keep decrypting for as long as it exists. Both keys are
# granted to both consumers for exactly that reason.
module "action_encryption_key" {
  source = "../../modules/payload-encryption-key"

  env        = local.env
  alias_name = "meandr-action-${local.env}"
  purpose    = "AEAD envelope key for elicitation + approval form payloads"

  enable_key_rotation     = true
  deletion_window_in_days = 7

  # The whole point of this key. IMMUTABLE — created right the first time
  # rather than flipped later, which is what the bucket key cannot do.
  multi_region = true

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

  # One token per environment, so an edge node needs THIS value — but read
  # from its own region, since it fetches at boot and a node that cannot
  # reach Secrets Manager does not start.
  dynamic "replica" {
    for_each = local.edge_regions
    content {
      region = replica.value
    }
  }
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

  # Every proxy task in the environment must verify with the same key —
  # an agent's next call can land in any region, and a session signed in
  # one must validate in another. Same value, local copy.
  dynamic "replica" {
    for_each = local.edge_regions
    content {
      region = replica.value
    }
  }
}

resource "aws_secretsmanager_secret_version" "session_signing_key" {
  secret_id     = aws_secretsmanager_secret.session_signing_key.id
  secret_string = random_password.session_signing_key.result
}

# --- Proxy wildcard TLS cert -------------------------------------------
#
# Terraform owns the CONTAINER and its replication; BE owns the VALUE.
# The cert is issued and renewed by the ACME pipeline (cert_store.md §5),
# which writes through Meandr::Secrets — create_secret, falling back to
# put_secret_value when it already exists. So declaring the shell here
# costs BE nothing and needs no code change.
#
# This exists ONLY to make replication declarative. The proxy resolves its
# cert by NAME against its own region's Secrets Manager, so an edge with
# no local copy gets ResourceNotFound and fails the TLS handshake — it
# would serve nothing, and only at the first request. A cert also renews
# roughly every 60 days, so the alternative (a copy per region) would mean
# an apply per region per renewal, failing silently on the one forgotten.
#
# NO aws_secretsmanager_secret_version here on purpose: the value is not
# Terraform's, and writing one would fight the renewal cron.
#
# Only OUR apexes live in SM — one per environment. Customer certs move to
# DynamoDB precisely because per-secret replication does not scale to
# them (cert_store.md §4.1).
resource "aws_secretsmanager_secret" "proxy_cert" {
  name        = "meandr/certs/${local.env}/${local.proxy_apex}"
  description = "TLS cert + key for *.${local.proxy_apex} (${local.env}). Written by the ACME pipeline; replication managed here."
  tags        = local.tags

  dynamic "replica" {
    for_each = local.edge_regions
    content {
      region = replica.value
    }
  }
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
module "internal_pki" {
  source = "../../modules/internal-pki"

  env           = local.env
  dns_zone_name = module.vpc.internal_dns_zone_name

  # One CA for the whole environment. It MUST be shared, not regenerated
  # per region: config replicates cross-region over mTLS, so an edge
  # replica presents a certificate the primary's master has to trust.
  #
  # The leaf needs no change — `*.valkey.<zone>` already covers every node
  # name in every region — so this adds read-only copies, nothing rotates.
  replica_regions = local.edge_regions

  tags = local.tags
}

module "valkey" {
  source = "../../modules/valkey-region"

  env         = local.env
  region      = local.region
  region_code = "euc1"

  fleets = {
    # Masters live here, so this region bootstraps every record and its
    # nodes stay promotable — an edge sets both false.
    config = {}

    # Region-qualified because the zone is shared: an unqualified
    # `events-master` would name a different node in every region.
    events = {
      master_record_label = "events-master-euc1"
    }

    # allkeys-lru unlike the other two — dropping the coldest key IS the
    # behaviour here. Rails-owned, and takes no backups.
    api = {
      maxmemory_policy      = "allkeys-lru"
      backup_bucket_enabled = false
    }
  }

  valkey_version     = local.valkey_version
  valkey_source_path = local.valkey_source_path
  backup_bucket      = local.valkey_backup_bucket

  auth_secret_arn = aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = module.internal_pki.node_secret_arn

  vpc_id        = module.vpc.vpc_id
  subnet_ids    = module.vpc.private_subnet_ids
  client_cidrs  = concat([module.vpc.vpc_cidr_block], local.edge_cidrs)
  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = local.tags
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

  # Every node in the region. A fleet missing here keeps the recipes it
  # already has and silently receives no new ones.
  instance_ids = concat(
    module.valkey.instance_ids,
  )

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

  # Same parameter the proxy reads, so BE validation and the proxy's dial
  # guard cannot disagree about what our own ingress is.
  self_ips_parameter_arn = "arn:aws:ssm:${local.region}:${local.account_id}:parameter${local.self_ips_param}"

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
  config_sentinel_addrs  = module.valkey.fleets["config"].sentinel_addrs
  config_sentinel_master = "config"

  event_sentinel_groups = [join(",", module.valkey.fleets["events"].sentinel_addrs)]
  event_sentinel_master = "events"

  api_sentinel_addrs  = module.valkey.fleets["api"].sentinel_addrs
  api_sentinel_master = "api"

  valkey_client_secret_arn = module.internal_pki.client_secret_arn

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

  # BE unwraps upstream form answers, which the proxy wrapped with the
  # action key. Granted alongside the bucket key, not instead of it.
  action_key_enabled          = true
  envelope_encryption_key_arn = module.action_encryption_key.key_arn
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

  # Every payloads bucket is one end of a replication pair — the primary
  # receives, a regional buffer sends (capture_and_archive.md §6.1) — and
  # S3 requires versioning on BOTH. Not local.primary: a buffer needs it
  # just as much, for the opposite reason.
  #
  # Enabled ahead of the first buffer because it lives in a different
  # state file. Without it, region 2's replication config fails to create
  # and that region stops being a single apply.
  versioning_enabled = true
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
  # OWN REGION FIRST, then every other region's.
  #
  # Order is load-bearing and does exactly one thing: Sentinel DISCOVERY
  # walks the list in order until one answers, and is not latency-aware.
  # Which REPLICA gets read is a separate mechanism — the client measures
  # RTT and picks the nearest (rdb.New, RouteByLatency) — so the remote
  # entries cost nothing while the local ones answer, and become the
  # difference between degraded and dead when they stop.
  config_reader_endpoint = module.valkey.fleets["config"].master_hostname
  config_sentinel_addrs = concat(
    module.valkey.fleets["config"].sentinel_addrs,
    flatten([
      for code in local.peer_node_codes : [
        for az in ["a", "b", "c"] :
        "config-${code}${az}.valkey.${module.vpc.internal_dns_zone_name}:26379"
      ]
    ]),
  )
  config_sentinel_master = "config"

  event_writer_endpoint = module.valkey.fleets["events"].master_hostname
  event_sentinel_addrs  = module.valkey.fleets["events"].sentinel_addrs
  event_sentinel_master = "events"

  # Required to reach either fleet: the nodes run `tls-auth-clients yes`
  # and refuse a connection with no client certificate.
  valkey_client_secret_arn = module.internal_pki.client_secret_arn

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
  capture_enabled            = true
  payloads_bucket            = module.payloads_bucket.bucket
  payloads_bucket_arn        = module.payloads_bucket.arn
  payload_encryption_key_arn = module.payload_encryption_key.key_arn

  # The ALIAS is the action key — it is what payloadcrypt wraps with. The
  # bucket key is granted above but never named in env: SSE-KMS is a
  # property of the bucket, not something the proxy chooses per write.
  action_key_enabled           = true
  envelope_encryption_key_arn  = module.action_encryption_key.key_arn
  payload_encryption_key_alias = module.action_encryption_key.alias_name

  # Staging customer-facing MCP traffic lands at *.meandr.live. Production
  # uses the module default *.meandr.io. The split keeps staging traffic
  # off the production-shaped hostname and lets us roll DNS / certs on
  # meandr.live without touching production's apex.
  #
  # Single-sourced with the cert secret below it: the proxy derives its
  # cert path from this apex, so the two cannot drift.
  dns_zone_name = local.proxy_apex

  # The authorization server lives on BE's zone, not the tenant wildcard
  # above — see the module's oauth_issuer_host. Kept dark until the record
  # resolves and BE answers on it; flipping the flag is the whole switch.
  oauth_issuer_host       = "staging-mcp.meandr.com"
  oauth_discovery_enabled = true

  proxy = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 60 }

  log_retention_days = 7

  # The accelerator owns *.meandr.live now. One apex means one owner, and
  # a second region creating it would have two state files overwriting each
  # other's answer.
  create_wildcard_record = false

  # Written per region by account-staging/ from the accelerator's anycast
  # pair. Derived, not copied: the same line works in every region, and the
  # value changes without a Terraform change here.
  self_ips_parameter_arn = "arn:aws:ssm:${local.region}:${local.account_id}:parameter${local.self_ips_param}"
}

# --- Global Accelerator endpoint ---------------------------------------
#
# The accelerator lives in account-staging/; each region attaches its own
# endpoint group, so the accelerator holds no list of regions.
#   terraform -chdir=../../account-staging output ga_listener_arn

resource "aws_globalaccelerator_endpoint_group" "local_region" {
  provider = aws.usw2

  listener_arn          = "arn:aws:globalaccelerator::259534890849:accelerator/3d7bdcd1-f6e6-478b-80cd-89cd8e5ce755/listener/929cbb6f"
  endpoint_group_region = local.region

  # An unhealthy group is withdrawn from the anycast pair, so a broken
  # deploy stops serving silently rather than erroring. Needs an alarm.
  health_check_protocol         = "TCP"
  health_check_port             = 443
  health_check_interval_seconds = 30
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id = module.mcp.nlb_arn
    weight      = 100

    # Without this the proxy sees accelerator addresses and clientguard's
    # per-client limits collapse onto a handful of sources.
    client_ip_preservation_enabled = true
  }
}

