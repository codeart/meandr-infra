# Section order matches eu-central-1 so the two files diff side by side.
# Where a section is absent, a comment says why rather than leaving a gap.

# Applications run in a and b ONLY; zone c carries the Sentinel arbiters.
locals {
  app_public_subnet_ids  = slice(module.vpc.public_subnet_ids, 0, 2)
  app_private_subnet_ids = slice(module.vpc.private_subnet_ids, 0, 2)
}

# --- VPC ---------------------------------------------------------------
#
# CIDR is a property of the REGION, not the environment, so this matches
# what production/us-east-1 will use. Safe because environments are
# separate accounts and never share a network (infra_inventory.md §10.3).

module "vpc" {
  source = "../../modules/vpc"

  env = local.env

  cidr_block = local.vpc_cidr
  # APPEND only — subnet ids are consumed positionally.
  azs        = ["${local.region}a", "${local.region}b", "${local.region}c"]
  enable_nat = true

  # One address serves every AZ, so coverage is free and only redundancy
  # costs. Verified 2026-08-26.
  nat_pinned_azs = ["${local.region}a"]

  # ASSOCIATE with the environment's existing zone; never create one. A
  # second zone of the same name resolves locally, so a replica told to
  # follow config-master would silently attach to the wrong master.
  existing_zone_id  = local.peer.internal_dns_zone_id
  internal_dns_zone = "${local.env}.meandr.internal"

  tags = local.tags
}

# --- Cross-region link (EDGE ONLY) --------------------------------------
#
# The primary has no such section: it names no edge, and both ends of every
# link are declared from the edge that needs it.
#
# Resolving a name is not reaching it — the shared zone gives the name,
# this gives the path, security-group CIDRs give admission
# (valkey_fleets.md §6).

module "peering" {
  source = "../../modules/region-peering"

  providers = {
    aws      = aws
    aws.peer = aws.primary_region
  }

  name = "${local.region} to ${local.peer.region}"

  vpc_id         = module.vpc.vpc_id
  cidr_block     = module.vpc.vpc_cidr_block
  route_table_id = module.vpc.private_route_table_id

  peer_vpc_id         = local.peer.vpc_id
  peer_region         = local.peer.region
  peer_cidr_block     = local.peer.cidr_block
  peer_route_table_id = local.peer.private_route_table

  tags = local.tags
}

# --- Credential store ---------------------------------------------------
#
# The primary CREATES the table; an edge attaches a replica. The table
# there carries a stream and no replica list, so regions are added without
# editing it. See docs/credential_store.md.

resource "aws_dynamodb_table_replica" "creds" {
  global_table_arn = "arn:aws:dynamodb:${local.peer.region}:${local.account_id}:table/meandr-creds-${local.env}"

  # No kms_key_arn: every replica must match the SOURCE table's key manager,
  # and that table is on aws/dynamodb. The cred MRK is the ENVELOPE key the
  # proxy decrypts blobs with — a different layer, passed to the mcp module.

  # Protected replicas cannot be removed, so a primary that tries fails its
  # apply instead of silently destroying this one.
  deletion_protection_enabled = true

  tags = local.tags
}

# --- Encryption keys ----------------------------------------------------
#
# The primary CREATES the cred and action keys; an edge replicates them.
# Both are multi-Region because their ciphertext crosses (SOC-2.md §2a).

module "kms_replicas" {
  source = "../../modules/kms-replica-keys"

  providers = {
    aws         = aws
    aws.primary = aws.primary_region
  }

  keys = {
    "meandr-cred-${local.env}"   = "Replica: server credentials"
    "meandr-action-${local.env}" = "Replica: elicitation + approval form envelopes"
  }

  tags = local.tags
}

# Regional, and deliberately unreplicable so it cannot be adopted for
# something that crosses. Each region encrypts only objects it reads, and
# S3 replication re-encrypts with the destination's key.
module "payload_encryption_key" {
  source = "../../modules/payload-encryption-key"

  env        = local.env
  alias_name = "meandr-payload-${local.env}-${local.region}"
  purpose    = "SSE-KMS default for this region's payload buffer"

  enable_key_rotation     = true
  deletion_window_in_days = 7
  multi_region            = false

  tags = local.tags
}

# Read, not replicated: replication needs it to re-encrypt into the
# primary's bucket.
data "aws_kms_key" "primary_payload" {
  provider = aws.primary_region
  key_id   = "alias/meandr-payload-${local.env}"
}

# --- Shared secrets -----------------------------------------------------
#
# The primary CREATES these and lists its edges as replica targets; an edge
# READS the local replica by name.
#
# Local by necessity: a node fetching cross-region could not boot while the
# primary was unreachable, which is the failure this topology survives.

data "aws_secretsmanager_secret" "redis_auth" {
  name = "meandr/redis/${local.env}/auth-token"
}

data "aws_secretsmanager_secret" "session_signing_key" {
  name = "meandr/session/${local.env}/signing-key"
}

# --- Internal PKI -------------------------------------------------------
#
# The primary MINTS the CA; an edge reads the replicated leaves. A second
# CA would break the cross-region mTLS that `config` replication runs over.

data "aws_secretsmanager_secret" "valkey_node" {
  name = "meandr/valkey/${local.env}/node"
}

data "aws_secretsmanager_secret" "valkey_client" {
  name = "meandr/valkey/${local.env}/client"
}

# --- Valkey ------------------------------------------------------------
#
# No `api` fleet: that one is BE-local, and BE lives in the primary.
#
# client_cidrs spans both VPCs because the primary's Sentinels must reach
# these nodes and SG references do not cross regions.

module "valkey" {
  source = "../../modules/valkey-region"

  env         = local.env
  region      = local.region
  region_code = local.region_code

  fleets = {
    # An edge holds no master: `config-master` is global and the primary
    # owns the name, and replica-priority 0 means a partition finds no
    # candidate here rather than a second master.
    config = {
      promotable           = false
      create_master_record = false
    }

    # Standalone per region, so a real master — region-qualified because
    # the zone is shared.
    events = {
      master_record_label = "events-master-${local.region_code}"
    }
  }

  instance_type         = local.valkey_instance_type
  arbiter_instance_type = local.valkey_arbiter_type

  valkey_version     = local.valkey_version
  valkey_source_path = local.valkey_source_path
  backup_bucket      = local.valkey_backup_bucket

  auth_secret_arn = data.aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = data.aws_secretsmanager_secret.valkey_node.arn

  vpc_id        = module.vpc.vpc_id
  subnet_ids    = module.vpc.private_subnet_ids
  client_cidrs  = [module.vpc.vpc_cidr_block, local.peer.cidr_block]
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
#
# ABSENT. BE and Postgres are central; the region that runs them is the
# primary by definition.

# --- Archive ------------------------------------------------------------
#
# ABSENT. One archive bucket and one Glue database per environment, both in
# the primary — BE writes them from Postgres.

# --- Payloads: a BUFFER, not a peer store -------------------------------
#
# Written locally because the proxy is on the hot path, then replicated
# into the primary, which stays the single bucket BE and Athena read
# (capture_and_archive.md §6.1).

module "payloads_bucket" {
  source = "../../modules/s3-capture-bucket"

  name        = "meandr-mcp-payloads-${local.region}-${local.env}"
  kms_key_arn = module.payload_encryption_key.key_arn
  tags        = local.tags

  # Buffer semantics: one clock for everything, no retention tags. This
  # side makes no retention promise — the primary does.
  retention_classes      = {}
  buffer_expiration_days = 7

  # Required on BOTH ends by S3 replication. The primary's flag lives in
  # another state file and had to be enabled there first.
  versioning_enabled = true

  replicate_to = {
    bucket_arn  = "arn:aws:s3:::meandr-mcp-payloads-${local.peer.region}-${local.env}"
    kms_key_arn = data.aws_kms_key.primary_payload.arn
  }
}

# --- Proxy --------------------------------------------------------------

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

  # Events is standalone per region — local Sentinels only, since a remote
  # one would name another region's master.
  event_writer_endpoint = module.valkey.fleets["events"].master_hostname
  event_sentinel_addrs  = module.valkey.fleets["events"].sentinel_addrs
  event_sentinel_master = "events"

  valkey_client_secret_arn = data.aws_secretsmanager_secret.valkey_client.arn

  redis_auth_enabled    = true
  redis_auth_secret_arn = data.aws_secretsmanager_secret.redis_auth.arn

  session_signing_key_secret_arn = data.aws_secretsmanager_secret.session_signing_key.arn

  cred_store_enabled      = true
  creds_table_name        = "meandr-creds-${local.env}"
  creds_table_arn         = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/meandr-creds-${local.env}"
  cred_encryption_key_arn = module.kms_replicas.key_arns["meandr-cred-${local.env}"]

  capture_enabled            = true
  payloads_bucket            = module.payloads_bucket.bucket
  payloads_bucket_arn        = module.payloads_bucket.arn
  payload_encryption_key_arn = module.payload_encryption_key.key_arn

  action_key_enabled           = true
  envelope_encryption_key_arn  = module.kms_replicas.key_arns["meandr-action-${local.env}"]
  payload_encryption_key_alias = module.kms_replicas.alias_names["meandr-action-${local.env}"]

  dns_zone_name = local.proxy_apex

  # The accelerator owns the apex record. Two regions creating it would be
  # two state files overwriting each other.
  create_wildcard_record = false

  # Reachable ONLY through the accelerator. A public NLB behind one is a
  # second front door that the proxy's self-IP guard does not know about.
  internal_nlb = true

  self_ips_parameter_arn = "arn:aws:ssm:${local.region}:${local.account_id}:parameter${local.self_ips_param}"

  oauth_issuer_host       = local.oauth_issuer_host
  oauth_discovery_enabled = true

  proxy = local.proxy

  log_retention_days = local.log_retention_days
}

# --- Global Accelerator endpoint ----------------------------------------
#
# Attaches this region to the accelerator in account-staging/, which holds
# no list of regions.
#   terraform -chdir=../../account-staging output ga_listener_arn

locals {
  # Deterministic from region + account + name — no literal, no lookup.
  ga_alerts_topic_arn = "arn:aws:sns:us-west-2:${local.account_id}:meandr-${local.env}-ga-alerts"

  # CloudWatch dimension values, both path segments of the listener arn.
  ga_accelerator_id = split("/", local.ga_listener_arn)[1]
  ga_listener_id    = split("/", local.ga_listener_arn)[3]
}

resource "aws_globalaccelerator_endpoint_group" "local_region" {
  provider = aws.usw2

  listener_arn          = local.ga_listener_arn
  endpoint_group_region = local.region

  # An unhealthy group is withdrawn from the anycast pair, so a broken
  # deploy stops serving silently rather than erroring — hence the alarm
  # below. 3 checks at 30s means withdrawal takes ~90s.
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

# This region withdrawn from the anycast pair. Traffic still serves from the
# others, which is why nothing else reports it.
resource "aws_cloudwatch_metric_alarm" "ga_endpoint_unhealthy" {
  provider = aws.usw2

  alarm_name        = "meandr-${local.env}-ga-unhealthy-${local.region}"
  alarm_description = "Global Accelerator withdrew ${local.region}; it is serving no anycast traffic."

  namespace   = "AWS/GlobalAccelerator"
  metric_name = "HealthyEndpointCount"
  dimensions = {
    Accelerator   = local.ga_accelerator_id
    Listener      = local.ga_listener_id
    EndpointGroup = local.region
  }

  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2

  # Silence is the failure being alarmed on, so absent data is not healthy.
  treat_missing_data = "breaching"

  alarm_actions = [local.ga_alerts_topic_arn]
  ok_actions    = [local.ga_alerts_topic_arn]
  tags          = local.tags
}
