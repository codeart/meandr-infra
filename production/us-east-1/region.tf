# THE ONLY FILE THAT DIFFERS BETWEEN REGIONS.
#
# Onboarding a region is: copy the directory, edit this file, adjust
# backend.tf's key. Everything else should be identical.

locals {
  env        = "production"
  region     = "us-east-1"
  account_id = "393686273464"

  # Named because recipes run SSM from the OPERATOR's machine, where there
  # is no provider to inherit credentials from.
  aws_profile = "meandr-production"

  # Holds the one-per-environment resources: the archive bucket and its
  # Glue database. Not derived from the api module — production reserves
  # the archive name before its workload lands, and dev writes an archive
  # with no ECS. See infra_inventory.md §10.
  primary = true

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

  # --- Network ---------------------------------------------------------
  #
  # CIDR is a property of the REGION, not the environment: environments are
  # separate accounts and never share a network, so this matches staging's
  # us-east-1.
  vpc_cidr = "10.20.0.0/16"

  # Two addresses, in the two zones that carry workloads. Staging pins one
  # because a single idle address is the cheaper risk there; production
  # pays for the second so losing AZ-a does not take egress with it.
  nat_pinned_azs = ["${local.region}a", "${local.region}b"]

  # --- Accelerator -----------------------------------------------------
  #
  # A literal because there IS no listener data source — only the
  # accelerator has one, and the listener id is AWS-generated. Remote state
  # would work and is deliberately not used: it would give every region a
  # read dependency on the account stack rather than a provider alias.
  #   terraform -chdir=../../account-production output ga_listener_arn
  ga_listener_arn = "arn:aws:globalaccelerator::393686273464:accelerator/ccbf8f26-3a26-4193-97c9-95d5f47017cf/listener/5f307d6b"

  # --- Durability ------------------------------------------------------
  #
  # Staging data is rebuildable and iterated on; production is neither.
  pitr_enabled        = true
  kms_deletion_window = 30
  db_multi_az         = true
  log_retention_days  = 30

  # --- Public names ----------------------------------------------------
  image_tag         = "main"
  api_hostname      = "api.meandr.com"
  oauth_issuer_host = "mcp.meandr.com"
  acme_dns_role_arn = "arn:aws:iam::303529433558:role/meandr-acme-dns-${local.env}"

  # --- Sizing ----------------------------------------------------------
  db_instance_class = "db.t4g.small"
  puma              = { cpu = 512, memory = 1024, desired_count = 2, min_replicas = 2, max_replicas = 8, target_cpu_utilization = 70, concurrency : 0, threads : 6 }
  jobs              = { cpu = 512, memory = 1024, desired_count = 1, min_replicas = 1, max_replicas = 6, target_cpu_utilization = 70 }
  ingest            = { cpu = 512, memory = 1024, desired_count = 1 }
  migrate           = { cpu = 512, memory = 1024 }
  proxy             = { cpu = 512, memory = 1024, desired_count = 2, min_replicas = 2, max_replicas = 10, target_cpu_utilization = 60 }

  # --- What this region knows about the others -------------------------
  #
  # Three lists, all environment configuration rather than dependencies:
  # nothing here reads another region's state, and each edge still declares
  # its own peering, replicas and routes.

  # Secrets Manager replica targets. The one thing that cannot be inverted —
  # there is no edge-owned replica resource, only a `replica` block on the
  # secret in its home region. Copies must move together without an apply,
  # because these values are what the cross-region link authenticates with.
  #
  # Empty: single-region today. An edge adds itself here and declares its
  # own peering, KMS replicas and table replica in its own state.
  edge_regions = []

  # Security-group ingress for the Valkey fleets. Literal CIDRs because SG
  # REFERENCES DO NOT CROSS REGIONS (valkey_fleets.md §6). Safe to widen:
  # client_cidrs never reaches user_data, so an entry adds rules and
  # replaces no node.
  edge_cidrs = []

  # Every OTHER region: name -> node-name prefix. Drives the CONFIG Sentinel
  # list (one set spanning regions, so a proxy here can discover through a
  # Sentinel there when its own are gone) and BE's per-region event groups.
  #
  # A map, not two lists: keys() and values() share one order, which is what
  # keeps `regions` and `event_sentinel_groups` positionally aligned.
  peers = {}

  peer_node_codes = values(local.peers)

  tags = {
    "meandr:env"        = local.env
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}
