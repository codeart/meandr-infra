# Applications run in a and b ONLY; zone c carries the Sentinel arbiters.
locals {
  app_public_subnet_ids  = slice(module.vpc.public_subnet_ids, 0, 2)
  app_private_subnet_ids = slice(module.vpc.private_subnet_ids, 0, 2)
}

# --- VPC ---------------------------------------------------------------
#
# 10.20.0.0/16 — CIDR is a property of the REGION, not the environment, so
# this matches what production/us-east-1 will use. Safe because environments
# are separate accounts and never share a network; the only pair that can
# then never peer is staging-use1 <-> prod-use1, which should never talk.
# See infra_inventory.md §10.3.

module "vpc" {
  source = "../../modules/vpc"

  cidr_block = "10.20.0.0/16"
  # APPEND only — subnet ids are consumed positionally.
  azs        = ["${local.region}a", "${local.region}b", "${local.region}c"]
  enable_nat = true

  # One address, as in eu-central-1: a regional NAT serves every AZ from
  # whatever zones hold an address, so coverage is free and only redundancy
  # costs. Verified in staging 2026-08-26 — nodes in all three AZs egressed
  # through a single 1a address.
  nat_pinned_azs = ["${local.region}a"]

  # ASSOCIATE with the environment's existing zone; do not create one. A
  # second zone of the same name is the collision the whole naming scheme
  # exists to prevent: names resolve locally, so a replica told to follow
  # config-master would silently attach to whatever answers at home.
  existing_zone_id  = local.peer.internal_dns_zone_id
  internal_dns_zone = "${local.env}.meandr.internal"

  tags = local.tags
}

# --- Peering to the primary --------------------------------------------
#
# Required for the `config` fleet: this region's replicas dial the primary's
# master on 6379, and all six Sentinels gossip both ways on 26379. Resolving
# a name is not reaching it — the shared zone gives us the first, peering the
# second (valkey_fleets.md §6).
#
# BOTH ends live here, via the euc1 alias, so adding this region touches no
# resource owned by eu-central-1's state file. Peering is not transitive: a
# third region needs its own connections or a Transit Gateway.

module "peering" {
  source = "../../modules/region-peering"

  providers = {
    aws      = aws
    aws.peer = aws.euc1
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

# --- Shared trust material (replicated, not minted here) ----------------
#
# The edge does NOT call modules/valkey-tls. That module CREATES a CA, and
# a second CA would defeat the point: `config` replicates cross-region over
# mTLS, so an edge replica has to present a certificate the primary's master
# already trusts. One CA per environment, replicated (valkey_fleets.md §4).
#
# Same for the AUTH token — one per environment, or the edge cannot
# authenticate to the primary's master at all.
#
# Read by NAME from the LOCAL region: Secrets Manager is regional, and these
# resolve because eu-central-1 declares us in its replica list. A node that
# had to fetch cross-region would fail to boot whenever the primary was
# unreachable, which is the failure this topology exists to survive.

data "aws_secretsmanager_secret" "valkey_node" {
  name = "meandr/valkey/${local.env}/node"
}

data "aws_secretsmanager_secret" "redis_auth" {
  name = "meandr/redis/${local.env}/auth-token"
}


# --- Valkey ------------------------------------------------------------
#
# No `api` fleet: that one is BE-local and BE lives in the primary.
#
# client_cidrs spans both VPCs because the primary's Sentinels must reach
# these nodes, and security-group references do not cross regions
# (valkey_fleets.md §6).

module "valkey" {
  source = "../../modules/valkey-region"

  env         = local.env
  region      = local.region
  region_code = "use1"

  fleets = {
    # An edge holds no master: `config-master` is global and eu-central-1
    # owns the name, and replica-priority 0 means a partition finds no
    # candidate here rather than a second master.
    config = {
      promotable           = false
      create_master_record = false
    }

    # Standalone per region, so a real master — region-qualified because
    # the zone is shared.
    events = {
      master_record_label = "events-master-use1"
    }
  }

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

  # Every node in the region. A fleet missing here keeps the recipes it
  # already has and silently receives no new ones.
  instance_ids = concat(
    module.valkey.instance_ids,
  )

  aws_profile = local.aws_profile
  aws_region  = local.region
}

# --- Keys the edge attaches itself to -----------------------------------
#
# Read through the euc1 alias rather than hardcoded: same account, so a
# data source is cheaper than an ARN nobody will remember to update.

# The payload key is NOT replicated — it is regional by design. Read only
# so replication can re-encrypt into the primary's bucket.
data "aws_kms_key" "primary_payload" {
  provider = aws.euc1
  key_id   = "alias/meandr-payload-${local.env}"
}

module "kms_replicas" {
  source = "../../modules/kms-replica-keys"

  providers = {
    aws         = aws
    aws.primary = aws.euc1
  }

  keys = {
    "meandr-cred-${local.env}"   = "Replica: server credentials"
    "meandr-action-${local.env}" = "Replica: elicitation + approval form envelopes"
  }

  tags = local.tags
}

# The payload key is NOT replicated — it is regional by design, and
# deliberately unreplicable so it cannot be adopted for something that
# crosses regions. This region gets its OWN, because each region encrypts
# only objects it reads itself and S3 replication re-encrypts with the
# destination's key on the way to the primary. See SOC-2.md §2a.
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

# The creds table replica. Declared by the edge, not listed by the primary —
# the table there carries a stream (making it replicable) and no replica
# list, so regions are added and removed without editing it.
resource "aws_dynamodb_table_replica" "creds" {
  global_table_arn = "arn:aws:dynamodb:${local.peer.region}:${local.account_id}:table/meandr-creds-${local.env}"

  # The proxy resolves upstream credentials on the request path and decrypts
  # with the replica key above, so nothing about a tool call leaves this
  # region.
  kms_key_arn = module.kms_replicas.key_arns["meandr-cred-${local.env}"]

  tags = local.tags
}

# --- Payloads: a BUFFER, not a peer store -------------------------------
#
# Region 2 does not keep payloads. It writes them locally — the proxy is on
# the hot path and cannot cross an ocean to store a body — and replicates
# into the primary, which stays the single bucket BE and Athena read. That
# is what keeps the backend topology-blind as regions come and go
# (capture_and_archive.md §6.1).
#
# Versioning is required on BOTH ends by S3 replication; the primary was
# flipped ahead of this, since it lives in another state file and its
# absence would have made this region fail to apply.

module "payloads_bucket" {
  source = "../../modules/s3-capture-bucket"

  name        = "meandr-mcp-payloads-${local.region}-${local.env}"
  kms_key_arn = module.payload_encryption_key.key_arn
  tags        = local.tags

  # Buffer semantics: one clock for everything, no retention tags. This
  # side makes no retention promise — the primary does — so a catch-all is
  # correct here and wrong there.
  retention_classes      = {}
  buffer_expiration_days = 7

  versioning_enabled = true

  # Into the primary, which BE and Athena read. Versioning had to be
  # enabled there first — it lives in another state file.
  replicate_to = {
    bucket_arn  = "arn:aws:s3:::meandr-mcp-payloads-${local.peer.region}-${local.env}"
    kms_key_arn = data.aws_kms_key.primary_payload.arn
  }
}

# --- Replicated secrets, read locally -----------------------------------
#
# Written in eu-central-1 and replicated here; a cross-region fetch would
# fail to boot this region whenever the primary is unreachable.

data "aws_secretsmanager_secret" "session_signing_key" {
  name = "meandr/session/${local.env}/signing-key"
}

data "aws_secretsmanager_secret" "valkey_client" {
  name = "meandr/valkey/${local.env}/client"
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

  # `config-master` is global and resolves through the shared zone, so this
  # bootstrap address is the same string in every region. Sentinel plus
  # latency routing is what actually picks a replica.
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

  # Events is standalone per region — local Sentinels only, and a remote
  # one would name another region's master.
  event_writer_endpoint = module.valkey.fleets["events"].master_hostname
  event_sentinel_addrs  = module.valkey.fleets["events"].sentinel_addrs
  event_sentinel_master = "events"

  valkey_client_secret_arn = data.aws_secretsmanager_secret.valkey_client.arn

  redis_auth_enabled    = true
  redis_auth_secret_arn = data.aws_secretsmanager_secret.redis_auth.arn

  session_signing_key_secret_arn = data.aws_secretsmanager_secret.session_signing_key.arn

  # The Global Table replica and the KMS replica key, both declared by this
  # region. Same table name everywhere; the ARN is regional.
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

  # The accelerator owns *.meandr.live. Two regions creating it would be
  # two state files overwriting each other.
  create_wildcard_record = false

  self_ips_parameter_arn = "arn:aws:ssm:${local.region}:${local.account_id}:parameter${local.self_ips_param}"

  oauth_issuer_host       = "staging-mcp.meandr.com"
  oauth_discovery_enabled = true

  proxy = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 60 }

  log_retention_days = 7
}

# --- Global Accelerator endpoint ----------------------------------------
#
# Attaches this region to the accelerator in account-staging/, which holds
# no list of regions.
#   terraform -chdir=../../account-staging output ga_listener_arn

resource "aws_globalaccelerator_endpoint_group" "local_region" {
  provider = aws.usw2

  listener_arn          = "arn:aws:globalaccelerator::259534890849:accelerator/3d7bdcd1-f6e6-478b-80cd-89cd8e5ce755/listener/929cbb6f"
  endpoint_group_region = local.region

  health_check_protocol         = "TCP"
  health_check_port             = 443
  health_check_interval_seconds = 30
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = module.mcp.nlb_arn
    weight                         = 100
    client_ip_preservation_enabled = true
  }
}
