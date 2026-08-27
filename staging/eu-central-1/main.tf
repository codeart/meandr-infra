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

# --- Credential store ---------------------------------------------------
#
# The primary CREATES the table; an edge attaches a replica. The table
# carries a stream and no replica list, so regions are added without
# editing it. See docs/credential_store.md.

module "creds_table" {
  source = "../../modules/dynamodb-creds-table"

  name = "meandr-creds-${local.env}"

  pitr_enabled = false # staging: throwaway data, no audit need

  # A protected replica cannot be removed either, which is what turns an
  # accidental replica destroy into a failed apply. Flip false and apply
  # before an intentional teardown.
  deletion_protection_enabled = true

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

  # Ciphertext CROSSES: BE encrypts once, the Global Table replicates it,
  # and every region's proxy decrypts that same blob. Replicas are declared
  # by the edge — this flag only makes the key replicable.
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

  # Regional, and deliberately unreplicable so it cannot be adopted for
  # something that crosses. Each region encrypts only objects it reads, and
  # S3 replication re-encrypts with the destination's key. Flipping this
  # recreates the CMK and orphans every object already written.
  multi_region = false

  tags = local.tags
}

# Wraps the answer to an UPSTREAM-initiated elicitation, which can ask for
# anything. Our own approval form stays plaintext — it is an OTP that BE
# must read to validate. See buildResponded in action_responded.go.
#
# Multi-region because a form is wrapped at the edge that handled it and
# unwrapped by BE in the primary; a replica each side keeps both KMS calls
# local. Separate from the bucket key for that geography alone.
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

# --- Shared secrets -----------------------------------------------------
#
# The primary CREATES these and lists its edges as replica targets; an edge
# READS the local replica by name.
#
# One AUTH token per env across all three fleets. Network isolation stays
# the trust boundary; AUTH is defense-in-depth. Rotate by changing the
# random_password length or keepers.

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

# Terraform owns the CONTAINER and its replication; the ACME pipeline owns
# the VALUE (cert_store.md §5). NO secret_version here — writing one would
# fight the renewal cron.
#
# Declared only to make replication automatic: the proxy resolves its cert
# by name in its own region, and a renewal every 60 days would otherwise
# mean an apply per region, failing silently on the one forgotten.
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

# --- Internal PKI -------------------------------------------------------
#
# The primary MINTS the CA; an edge reads the replicated leaves. A second
# CA would break the cross-region mTLS that `config` replication runs over.

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



module "valkey_recipes" {
  source = "../../modules/valkey-recipes"

  # Every node in the region. A fleet missing here keeps the recipes it has
  # and silently receives no new ones.
  instance_ids = module.valkey.instance_ids

  aws_profile = local.aws_profile
  aws_region  = local.region
}

# --- meandr-api ---------------------------------------------------------

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

  # Staging holds real developer credentials and dashboard state; it is not
  # scratch. Flip false and apply before an intentional teardown.
  db_deletion_protection = true

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

  # OWN REGION FIRST, then every other region's. Discovery walks the list
  # in order and is not latency-aware; which replica gets READ is chosen by
  # measured RTT in the client (rdb.New).
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

