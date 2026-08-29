# THE ONLY FILE THAT DIFFERS BETWEEN REGIONS.
#
# Onboarding a region is: copy the directory, edit this file, adjust
# backend.tf's key. Everything else should be identical.

locals {
  env    = "production"
  region = "eu-central-1"

  # Set beside `region` because the two must move together. It is in every
  # Valkey hostname, and the internal zone is ONE zone shared by every
  # region, so a stale code collides with a live region's records.
  region_code = "euc1"

  account_id = "393686273464"

  # Named because recipes run SSM from the OPERATOR's machine, where there
  # is no provider to inherit credentials from.
  aws_profile = "meandr-production"

  # An EDGE. No archive bucket, no Glue database, no meandr-api, and no
  # `api` Valkey fleet — all of those are one-per-environment and live in
  # the primary. See infra_inventory.md §10.
  primary = false

  # Public apex this region's proxy serves. Drives the cert path the proxy
  # reads at handshake time, so it cannot disagree with DNS.
  proxy_apex = "meandr.io"

  # Written by account-production/ into every region. Same path everywhere.
  self_ips_param = "/meandr/production/self-ips"

  # Upgrade order is replicas first, master last: a replica newer than its
  # master is safe, the reverse is not. A version with no vendored tarball
  # fails at plan. See valkey_fleets.md.
  valkey_version       = "9.1.1"
  valkey_source_path   = "${path.root}/../../modules/valkey-node/vendor/valkey-${local.valkey_version}.tar.gz"
  valkey_backup_bucket = "meandr-valkey-backups-${local.env}-${local.region}"

  # Data nodes carry Valkey; arbiters carry a Sentinel vote and nothing
  # else. Explicit rather than defaulted so an edge cannot end up a size
  # below its own primary without anyone choosing that.
  valkey_instance_type = "t4g.micro"
  valkey_arbiter_type  = "t4g.nano"

  # --- Region and environment specifics --------------------------------
  #
  # Hoisted out of main.tf so both edges share one. CIDR is a property of
  # the REGION (environments are separate accounts and never share a
  # network); the rest are properties of the ENVIRONMENT.
  vpc_cidr          = "10.10.0.0/16"
  oauth_issuer_host = "mcp.meandr.com"
  proxy             = { cpu = 512, memory = 1024, desired_count = 2, min_replicas = 2, max_replicas = 10, target_cpu_utilization = 60 }

  log_retention_days = 30

  # --- Accelerator -----------------------------------------------------
  #
  # A literal because there IS no listener data source — only the
  # accelerator has one, and the listener id is AWS-generated. Remote state
  # would work and is deliberately not used: it would give every region a
  # read dependency on the account stack rather than a provider alias.
  #   terraform -chdir=../../account-production output ga_listener_arn
  ga_listener_arn = "arn:aws:globalaccelerator::393686273464:accelerator/ccbf8f26-3a26-4193-97c9-95d5f47017cf/listener/5f307d6b"

  # --- What this region knows about the others -------------------------
  #
  # The EDGE names the primary; the primary names no edge. That direction
  # is what lets a region be added or removed without touching the
  # primary's state file.

  # Hardcoded rather than read from remote state, so this stack's only
  # cross-stack dependency stays the provider alias — the same call made
  # for acme_dns_role_arn. Retrieve with:
  #   terraform -chdir=../us-east-1 output vpc_id
  peer = {
    vpc_id              = "vpc-0464292fbee35fb21"
    cidr_block          = "10.20.0.0/16"
    private_route_table = "rtb-0d3a477edde8bdaa3"
    region              = "us-east-1"

    # The environment's ONE private hosted zone, created in the primary.
    # This region ASSOCIATES with it and must never create its own of the
    # same name — see modules/vpc/variables.tf existing_zone_id.
    internal_dns_zone_id = "Z0498539TDE0PRB2TS05"
  }

  # An edge replicates no secrets outward and admits no other region's
  # nodes; the primary holds both lists. Present so the two region files
  # stay comparable.
  edge_regions = []
  edge_cidrs   = []

  # Node-name prefixes for every OTHER region, used to build the CONFIG
  # Sentinel list — one set spanning regions, so a proxy here can discover
  # through a Sentinel there when its own are gone. Not for `events`, whose
  # fleets are per-region with their own masters.
  peer_node_codes = ["use1"]

  tags = {
    "meandr:env"        = local.env
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
    "meandr:role"       = "edge"
  }
}
