# THE ONLY FILE THAT DIFFERS BETWEEN REGIONS.
#
# Onboarding a region is: copy the directory, edit this file, adjust
# backend.tf's key. Everything else should be identical.

locals {
  env        = "staging"
  region     = "eu-central-1"
  account_id = "259534890849"

  # Named because recipes run SSM from the OPERATOR's machine, where there
  # is no provider to inherit credentials from.
  aws_profile = "meandr-staging"

  # Holds the one-per-environment resources: the archive bucket and its
  # Glue database. Not derived from the api module — production reserves
  # the archive name before its workload lands, and dev writes an archive
  # with no ECS. See infra_inventory.md §10.
  primary = true

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
  # Three lists, all environment configuration rather than dependencies:
  # nothing here reads another region's state, and each edge still declares
  # its own peering, replicas and routes.

  # Secrets Manager replica targets. The one thing that cannot be inverted —
  # there is no edge-owned replica resource, only a `replica` block on the
  # secret in its home region. Copies must move together without an apply,
  # because these values are what the cross-region link authenticates with.
  edge_regions = ["us-east-1"]

  # Security-group ingress for the Valkey fleets. Literal CIDRs because SG
  # REFERENCES DO NOT CROSS REGIONS (valkey_fleets.md §6). Safe to widen:
  # client_cidrs never reaches user_data, so an entry adds rules and
  # replaces no node.
  edge_cidrs = ["10.20.0.0/16"]

  # Node-name prefixes for every OTHER region, used to build the CONFIG
  # Sentinel list — one set spanning regions, so a proxy here can discover
  # through a Sentinel there when its own are gone. Not for `events`, whose
  # fleets are per-region with their own masters.
  peer_node_codes = ["use1"]

  tags = {
    "meandr:env"        = local.env
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}
