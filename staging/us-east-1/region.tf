# THE ONLY FILE THAT DIFFERS BETWEEN REGIONS.
#
# Onboarding a region is: copy the directory, edit this file, adjust
# backend.tf's key. Everything else should be identical.

locals {
  env        = "staging"
  region     = "us-east-1"
  account_id = "259534890849"

  # Named because recipes run SSM from the OPERATOR's machine, where there
  # is no provider to inherit credentials from.
  aws_profile = "meandr-staging"

  # An EDGE. No archive bucket, no Glue database, no meandr-api, and no
  # `api` Valkey fleet — all of those are one-per-environment and live in
  # the primary. See infra_inventory.md §10.
  primary = false

  # Public apex this region's proxy serves. Drives the cert path the proxy
  # reads at handshake time, so it cannot disagree with DNS.
  proxy_apex = "meandr.live"

  # Written by account-staging/ into every region. Same path everywhere.
  self_ips_param = "/meandr/staging/self-ips"

  # Upgrade order is replicas first, master last: a replica newer than its
  # master is safe, the reverse is not. A version with no vendored tarball
  # fails at plan. See valkey_fleets.md.
  valkey_version       = "9.1.1"
  valkey_source_path   = "${path.root}/../../modules/valkey-node/vendor/valkey-${local.valkey_version}.tar.gz"
  valkey_backup_bucket = "meandr-valkey-backups-${local.env}-${local.region}"

  # --- What this region knows about the others -------------------------
  #
  # The EDGE names the primary; the primary names no edge. That direction
  # is what lets a region be added or removed without touching the
  # primary's state file.

  # Hardcoded rather than read from remote state, so this stack's only
  # cross-stack dependency stays the provider alias — the same call made
  # for acme_dns_role_arn. Retrieve with:
  #   terraform -chdir=../eu-central-1 output vpc_id
  peer = {
    vpc_id              = "vpc-0cbe1504d75b750d2"
    cidr_block          = "10.10.0.0/16"
    private_route_table = "rtb-0e0e83bd1a54564d5"
    region              = "eu-central-1"

    # The environment's ONE private hosted zone, created in the primary.
    # This region ASSOCIATES with it and must never create its own of the
    # same name — see modules/vpc/variables.tf existing_zone_id.
    internal_dns_zone_id = "Z05780018F0P6ONCICNQ"
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
  peer_node_codes = ["euc1"]

  tags = {
    "meandr:env"        = local.env
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
    "meandr:role"       = "edge"
  }
}
