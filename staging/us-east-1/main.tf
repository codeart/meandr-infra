# staging / us-east-1 — EDGE region.
#
# Structurally identical to eu-central-1: the same fleets, the same three
# nodes each, the same shape. Role is the only difference, and it changes
# exactly one thing — whether a `config` node may be promoted to master.
# See valkey_fleets.md §1.
#
# What an edge does NOT run: meandr-api (BE and Postgres are central), the
# archive bucket and Glue database (one per environment, written by BE from
# Postgres), and the `api` Valkey fleet (BE-local).
#
# What it declares FOR ITSELF, rather than the primary declaring on its
# behalf: its DynamoDB table replica, its KMS replica key, its payloads
# bucket replication, and both ends of the VPC peering. The primary holds
# no list of its edges — see the note on local.peer below.

provider "aws" {
  region  = local.region
  profile = local.aws_profile
}

# The primary region. Used for the peering accepter, the Frankfurt-side
# route, and the resources this edge attaches itself to.
provider "aws" {
  alias   = "euc1"
  region  = "eu-central-1"
  profile = local.aws_profile
}

# meandr.com + meandr.live hosted zones live in the Shared account.
provider "aws" {
  alias   = "shared"
  region  = "eu-central-1"
  profile = "meandr-shared"
}

locals {
  env        = "staging"
  region     = "us-east-1"
  account_id = "259534890849"

  aws_profile = "meandr-staging"

  # NOT the primary. Gates the archive bucket, the Glue database and the
  # `api` fleet out, and pins every `config` node non-promotable.
  primary = false

  # The primary's identifiers, hardcoded rather than read from its remote
  # state — the same call made for acme_dns_role_arn, and for the same
  # reason: this stack's only cross-stack dependency stays the provider
  # alias. Retrieve with:
  #   terraform -chdir=../eu-central-1 output vpc_id
  #   terraform -chdir=../eu-central-1 output vpc_cidr_block
  #
  # Note the direction. The EDGE names the primary; the primary names no
  # edge. That is what lets a region be added or removed without touching
  # eu-central-1's state file.
  peer = {
    vpc_id              = "vpc-0cbe1504d75b750d2"
    cidr_block          = "10.10.0.0/16"
    private_route_table = "rtb-0e0e83bd1a54564d5"
    region              = "eu-central-1"

    # The environment's ONE private hosted zone, created in eu-central-1.
    # This region associates with it; it must never create its own of the
    # same name. See modules/vpc/variables.tf existing_zone_id.
    internal_dns_zone_id = "Z05780018F0P6ONCICNQ"
  }

  # Node-name prefixes for every OTHER region, for the CONFIG Sentinel
  # list. Mirror of the same local in eu-central-1 — see the comment there.
  peer_node_codes = ["euc1"]

  valkey_version     = "9.1.1"
  valkey_source_path = "${path.root}/../../modules/valkey-node/vendor/valkey-${local.valkey_version}.tar.gz"

  # A literal, not the bucket's id: the node module gates backup IAM on a
  # count, and count must be knowable at plan time.
  valkey_backup_bucket = "meandr-valkey-backups-${local.env}-${local.region}"

  tags = {
    "meandr:env"        = local.env
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
    "meandr:role"       = "edge"
  }
}

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

resource "aws_vpc_peering_connection" "primary" {
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = local.peer.vpc_id
  peer_region = local.peer.region

  # Cross-region peering cannot auto-accept; the accepter below does it.
  auto_accept = false

  tags = merge(local.tags, {
    Name = "${local.region} to ${local.peer.region}"
  })
}

resource "aws_vpc_peering_connection_accepter" "primary" {
  provider = aws.euc1

  vpc_peering_connection_id = aws_vpc_peering_connection.primary.id
  auto_accept               = true

  tags = merge(local.tags, {
    Name = "${local.peer.region} from ${local.region}"
  })
}

# DNS resolution across the link. Without this an instance resolving a peer
# hostname gets its PUBLIC address — which for private-only nodes is no
# address at all. The shared zone makes the name resolvable; this makes it
# resolve to the private IP from the other side.
resource "aws_vpc_peering_connection_options" "local" {
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.primary.id

  requester {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_vpc_peering_connection_options" "primary" {
  provider = aws.euc1

  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.primary.id

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

# Routes, both directions. The primary's table is edited from HERE — it is
# the one resource this stack touches in the other region, and it is additive:
# the module's routes are separate aws_route resources, so nothing here is
# clobbered by an apply of eu-central-1 (that is why they were split out).
resource "aws_route" "to_primary" {
  route_table_id            = module.vpc.private_route_table_id
  destination_cidr_block    = local.peer.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.primary.id
}

resource "aws_route" "from_primary" {
  provider = aws.euc1

  route_table_id            = local.peer.private_route_table
  destination_cidr_block    = module.vpc.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.primary.id
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

# --- Valkey artifacts ---------------------------------------------------
#
# Region-local by necessity: nodes fetch the source through the S3 GATEWAY
# ENDPOINT, which only reaches the regional service. A bucket in the primary
# would put NAT egress — and the internet — back on the boot path that
# vendoring the source exists to keep off it.

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

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "valkey_source" {
  bucket      = aws_s3_bucket.artifacts.id
  key         = "valkey/${local.valkey_version}/valkey-src.tar.gz"
  source      = local.valkey_source_path
  source_hash = filemd5(local.valkey_source_path)

  tags = local.tags
}

# TWO per AZ, not three: an edge runs `config` and `events` but no `api`
# fleet, which is BE-local. Six slots against a 32-vCPU quota.
#
# Apply this FIRST and alone — nothing binds an instance to a reservation,
# so the only thing that makes one count is existing before the launch:
#
#   terraform apply -target=aws_ec2_capacity_reservation.valkey_nano
#
# Never via depends_on on the node modules: that defers every data source
# inside them, local.user_data goes unknown at plan time, and
# user_data_replace_on_change silently stops firing — a user-data change
# then plans as an in-place update that never actually runs.
resource "aws_ec2_capacity_reservation" "valkey_nano" {
  for_each = toset(["${local.region}a", "${local.region}b", "${local.region}c"])

  instance_type           = "t4g.nano"
  instance_platform       = "Linux/UNIX"
  availability_zone       = each.value
  instance_count          = 2
  end_date_type           = "unlimited"
  instance_match_criteria = "open"

  tags = merge(local.tags, { Name = "valkey-nano-${each.value}" })
}

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

# --- Valkey: config tier (EDGE REPLICAS) --------------------------------
#
# Three nodes, same shape as the primary — m+s, r+s, s-only — but NONE of
# them may ever hold the master.
#
# `promotable = false` emits replica-priority 0, which makes them
# structurally ineligible rather than merely unlikely. A partition that
# isolates the primary therefore ends with these Sentinels agreeing the
# master is down and finding nothing they are permitted to promote: the
# failover dies for want of a candidate instead of splitting the fleet into
# two masters that both accept writes.
#
# `role = "replica"` on BOTH data nodes, unlike the primary where one is
# "master". That argument is only a bootstrap tie-break for when no master
# record resolves yet — and `config-master` already exists, created once in
# eu-central-1. These nodes read it and attach.
#
# There is deliberately NO aws_route53_record here. `config-master` is a
# GLOBAL name with one owner; a second region writing it would point every
# reader in the environment at a node that cannot serve writes.
#
# client_cidrs spans both VPCs: the primary's Sentinels must reach these
# nodes to monitor them, and security-group references do not cross regions
# (valkey_fleets.md §6), so the peer CIDR has to be named literally.

module "valkey_config_a" {
  source = "../../modules/valkey-node"

  fleet      = "config"
  node       = "use1a"
  role       = "replica"
  promotable = false

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  instance_type        = "t4g.nano"
  maxmemory_percent    = 50
  create_timeout       = "2m"

  backup_bucket = local.valkey_backup_bucket

  # Same quorum as every other node in the fleet, in every region —
  # Sentinels that disagree about what agreement means agree about nothing.
  # 2 does not scale with region count; see valkey_fleets.md §6.
  run_sentinel    = true
  sentinel_quorum = 2

  auth_secret_arn = data.aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = data.aws_secretsmanager_secret.valkey_node.arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[0] # AZ-a

  client_cidrs = [module.vpc.vpc_cidr_block, local.peer.cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "config" })
}

module "valkey_config_b" {
  source = "../../modules/valkey-node"

  fleet      = "config"
  node       = "use1b"
  role       = "replica"
  promotable = false

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  instance_type        = "t4g.nano"
  maxmemory_percent    = 50
  create_timeout       = "2m"

  backup_bucket = local.valkey_backup_bucket

  run_sentinel    = true
  sentinel_quorum = 2

  auth_secret_arn = data.aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = data.aws_secretsmanager_secret.valkey_node.arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[1] # AZ-b

  client_cidrs = [module.vpc.vpc_cidr_block, local.peer.cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "config" })
}

module "valkey_config_c" {
  source = "../../modules/valkey-node"

  fleet         = "config"
  node          = "use1c"
  role          = "replica"
  promotable    = false
  sentinel_only = true

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  instance_type        = "t4g.nano"
  create_timeout       = "2m"

  run_sentinel    = true
  sentinel_quorum = 2

  auth_secret_arn = data.aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = data.aws_secretsmanager_secret.valkey_node.arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[2] # AZ-c

  client_cidrs = [module.vpc.vpc_cidr_block, local.peer.cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "config" })
}

# --- Valkey: events tier (STANDALONE) -----------------------------------
#
# Nothing edge-specific here: `events` is one INDEPENDENT fleet per region,
# never replicated, so this region owns a real master and its nodes are
# promotable like any other. BE reaches across to read it — the only
# cross-region client in the system.
#
# Its Sentinel set is separate from eu-central-1's by construction: separate
# masters mean separate sets, three voters each, quorum 2. Losing all three
# loses this region's stream and nothing else, which is the accepted trade.

module "valkey_events_a" {
  source = "../../modules/valkey-node"

  fleet = "events"
  node  = "use1a"
  role  = "master"

  # Region-qualified, because the zone is shared. An unqualified
  # `events-master` would name a different node in every region while
  # resolving to whichever wrote it last. `config` needs no label — it has
  # one master globally, which is the point of that fleet.
  master_record_label = "events-master-use1"

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  instance_type        = "t4g.nano"
  maxmemory_percent    = 50
  create_timeout       = "2m"

  backup_bucket = local.valkey_backup_bucket

  run_sentinel    = true
  sentinel_quorum = 2

  auth_secret_arn = data.aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = data.aws_secretsmanager_secret.valkey_node.arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[0] # AZ-a

  # Includes the peer CIDR because BE — which lives in the primary region —
  # is this fleet's only reader.
  client_cidrs = [module.vpc.vpc_cidr_block, local.peer.cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "events" })
}

module "valkey_events_b" {
  source = "../../modules/valkey-node"

  fleet               = "events"
  node                = "use1b"
  role                = "replica"
  master_record_label = "events-master-use1"

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  instance_type        = "t4g.nano"
  maxmemory_percent    = 50
  create_timeout       = "2m"

  backup_bucket = local.valkey_backup_bucket

  run_sentinel    = true
  sentinel_quorum = 2

  auth_secret_arn = data.aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = data.aws_secretsmanager_secret.valkey_node.arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[1] # AZ-b — the point of the pair

  client_cidrs = [module.vpc.vpc_cidr_block, local.peer.cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "events" })
}

module "valkey_events_c" {
  source = "../../modules/valkey-node"

  fleet               = "events"
  node                = "use1c"
  role                = "replica"
  sentinel_only       = true
  master_record_label = "events-master-use1"

  valkey_version       = local.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(local.valkey_source_path)
  instance_type        = "t4g.nano"
  create_timeout       = "2m"

  run_sentinel    = true
  sentinel_quorum = 2

  auth_secret_arn = data.aws_secretsmanager_secret.redis_auth.arn
  tls_secret_arn  = data.aws_secretsmanager_secret.valkey_node.arn

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[2] # AZ-c

  client_cidrs = [module.vpc.vpc_cidr_block, local.peer.cidr_block]

  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = merge(local.tags, { "meandr:plane" = "events" })
}

# Bootstrapped once, then owned by Sentinel — ignore_changes is what stops
# the next apply pointing writers at a node demoted hours ago.
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

module "valkey_recipes" {
  source = "../../modules/valkey-recipes"

  instance_ids = [
    module.valkey_config_a.instance_id,
    module.valkey_config_b.instance_id,
    module.valkey_config_c.instance_id,
    module.valkey_events_a.instance_id,
    module.valkey_events_b.instance_id,
    module.valkey_events_c.instance_id,
  ]

  aws_profile = local.aws_profile
  aws_region  = local.region
}

# --- Keys the edge attaches itself to -----------------------------------
#
# Read through the euc1 alias rather than hardcoded: same account, so a
# data source is cheaper than an ARN nobody will remember to update.

data "aws_kms_key" "primary_cred" {
  provider = aws.euc1
  key_id   = "alias/meandr-cred-${local.env}"
}

data "aws_kms_key" "primary_action" {
  provider = aws.euc1
  key_id   = "alias/meandr-action-${local.env}"
}

data "aws_kms_key" "primary_payload" {
  provider = aws.euc1
  key_id   = "alias/meandr-payload-${local.env}"
}

# Replicas of the two multi-Region keys, declared HERE. The primary made
# them replicable (multi_region = true) without naming a region; this is
# the other half. Same key material, same key id, so ciphertext written in
# either region opens in both — which is the whole requirement, since
# Decrypt resolves the key from the blob and a regional key simply does not
# exist at this endpoint.

resource "aws_kms_replica_key" "cred" {
  description             = "Replica: server credentials (meandr-cred-${local.env})"
  primary_key_arn         = data.aws_kms_key.primary_cred.arn
  deletion_window_in_days = 7

  tags = local.tags
}

resource "aws_kms_alias" "cred" {
  name          = "alias/meandr-cred-${local.env}"
  target_key_id = aws_kms_replica_key.cred.key_id
}

resource "aws_kms_replica_key" "action" {
  description             = "Replica: elicitation + approval form envelopes (meandr-action-${local.env})"
  primary_key_arn         = data.aws_kms_key.primary_action.arn
  deletion_window_in_days = 7

  tags = local.tags
}

resource "aws_kms_alias" "action" {
  name          = "alias/meandr-action-${local.env}"
  target_key_id = aws_kms_replica_key.action.key_id
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
  kms_key_arn = aws_kms_replica_key.cred.arn

  tags = local.tags

  depends_on = [aws_kms_alias.cred]
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
}

# --- Replication into the primary ---------------------------------------

data "aws_iam_policy_document" "replication_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  name               = "meandr-payloads-replication-${local.env}-${local.region}"
  assume_role_policy = data.aws_iam_policy_document.replication_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "replication" {
  statement {
    sid    = "ReadSource"
    effect = "Allow"
    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
    ]
    resources = [module.payloads_bucket.arn]
  }

  statement {
    sid    = "ReadSourceObjects"
    effect = "Allow"
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
    ]
    resources = ["${module.payloads_bucket.arn}/*"]
  }

  statement {
    sid    = "WriteDestination"
    effect = "Allow"
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
    ]
    resources = ["arn:aws:s3:::meandr-mcp-payloads-${local.peer.region}-${local.env}/*"]
  }

  # Replication DECRYPTS with this region's key and RE-ENCRYPTS with the
  # primary's. That is why the payload keys can stay regional: no single
  # key ever spans regions, only this role does.
  statement {
    sid       = "DecryptLocal"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [module.payload_encryption_key.key_arn]
  }

  statement {
    sid       = "EncryptPrimary"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey"]
    resources = [data.aws_kms_key.primary_payload.arn]
  }
}

resource "aws_iam_role_policy" "replication" {
  name   = "replication"
  role   = aws_iam_role.replication.id
  policy = data.aws_iam_policy_document.replication.json
}

resource "aws_s3_bucket_replication_configuration" "buffer" {
  bucket = module.payloads_bucket.bucket
  role   = aws_iam_role.replication.arn

  rule {
    id     = "buffer-to-primary"
    status = "Enabled"

    filter {}

    # OFF, and load-bearing. With it on, the buffer's 7-day sweep could
    # propagate deletions into the primary — turning a local cleanup into
    # data loss in the bucket that holds the only copy. (S3 never replicates
    # LIFECYCLE-created markers, but this makes the guarantee explicit
    # rather than relying on that distinction.)
    delete_marker_replication {
      status = "Disabled"
    }

    # Objects here are SSE-KMS, and replication skips encrypted objects
    # unless told to handle them.
    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }

    destination {
      bucket = "arn:aws:s3:::meandr-mcp-payloads-${local.peer.region}-${local.env}"

      encryption_configuration {
        replica_kms_key_id = data.aws_kms_key.primary_payload.arn
      }
    }
  }
}

# --- Outputs -----------------------------------------------------------

output "vpc_id" { value = module.vpc.vpc_id }
output "vpc_cidr_block" { value = module.vpc.vpc_cidr_block }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }
output "public_subnet_ids" { value = module.vpc.public_subnet_ids }
output "peering_connection_id" { value = aws_vpc_peering_connection.primary.id }
