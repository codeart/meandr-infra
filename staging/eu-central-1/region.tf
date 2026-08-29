# THE ONLY FILE THAT DIFFERS BETWEEN REGIONS.
#
# Onboarding a region is: copy the directory, edit this file, adjust
# backend.tf's key. Everything else should be identical.

locals {
  env    = "staging"
  region = "eu-central-1"

  # Set beside `region` because the two must move together. It is in every
  # Valkey hostname, and the internal zone is ONE zone shared by every
  # region, so a stale code collides with a live region's records.
  region_code = "euc1"

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

  # --- Network ---------------------------------------------------------
  #
  # CIDR is a property of the REGION, not the environment: environments are
  # separate accounts and never share a network, so staging and production
  # in the same region use the same block.
  vpc_cidr = "10.10.0.0/16"

  # One address, in AZ-a, serving all three zones. AZ-c holds only the
  # Sentinel arbiters, which do not egress at steady state, and AZ-b's
  # workloads are processed by AZ-a's address — so a second address would
  # be paid for and idle. Production pins two.
  nat_pinned_azs = ["${local.region}a"]

  # --- Accelerator -----------------------------------------------------
  #
  # A literal because there IS no listener data source — only the
  # accelerator has one, and the listener id is AWS-generated. Remote state
  # would work and is deliberately not used: it would give every region a
  # read dependency on the account stack rather than a provider alias.
  #   terraform -chdir=../../account-staging output ga_listener_arn
  ga_listener_arn = "arn:aws:globalaccelerator::259534890849:accelerator/3d7bdcd1-f6e6-478b-80cd-89cd8e5ce755/listener/929cbb6f"

  # --- Durability ------------------------------------------------------
  #
  # Staging data is rebuildable and iterated on; production is neither.
  pitr_enabled        = false
  kms_deletion_window = 7
  db_multi_az         = false
  log_retention_days  = 7

  # --- Public names ----------------------------------------------------
  image_tag         = "develop"
  api_hostname      = "staging-api.meandr.com"
  oauth_issuer_host = "staging-mcp.meandr.com"
  acme_dns_role_arn = "arn:aws:iam::303529433558:role/meandr-acme-dns-${local.env}"

  # --- Sizing ----------------------------------------------------------
  #
  # Staging runs the smallest thing that exercises the topology. Production
  # uses m7g for the data nodes — see its region.tf for why the shape
  # matters more than the size.
  valkey_instance_type = "t4g.nano"
  valkey_arbiter_type  = "t4g.nano"

  db_instance_class = "db.t4g.micro"
  puma              = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 70, concurrency : 0, threads : 6 }
  jobs              = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 70 }
  ingest            = { cpu = 256, memory = 512, desired_count = 1 }
  migrate           = { cpu = 512, memory = 1024 }
  proxy             = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 60 }

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

  # Every OTHER region: name -> node-name prefix. Drives the CONFIG Sentinel
  # list (one set spanning regions, so a proxy here can discover through a
  # Sentinel there when its own are gone) and BE's per-region event groups.
  #
  # A map, not two lists: keys() and values() share one order, which is what
  # keeps `regions` and `event_sentinel_groups` positionally aligned.
  peers = { "us-east-1" = "use1" }

  peer_node_codes = values(local.peers)

  tags = {
    "meandr:env"        = local.env
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}
