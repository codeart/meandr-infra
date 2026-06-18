# staging / eu-central-1 — explicit module list. Onboarding a new region =
# copy this file, change identity vars (env, account, CIDR, hostname) +
# uncomment/comment module blocks per which apps run there.

provider "aws" {
  region  = "eu-central-1"
  profile = "meandr-staging"
}

# meandr.com + meandr.io hosted zones live in the Shared account — used for
# both ACM DNS validation and the public hostname records.
provider "aws" {
  alias   = "shared"
  region  = "eu-central-1"
  profile = "meandr-shared"
}

locals {
  env        = "staging"
  region     = "eu-central-1"
  account_id = "259534890849"

  tags = {
    "meandr:env" = local.env
  }
}

# --- VPC ---------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  cidr_block        = "10.10.0.0/16"
  azs               = ["eu-central-1a", "eu-central-1b"]
  enable_nat        = true
  internal_dns_zone = "${local.env}.meandr.local"

  tags = local.tags
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

module "config_stream" {
  source = "../../modules/elasticache-valkey"

  name        = "meandr-config-stream"
  description = "Config-stream Valkey staging - BE writes config + inbound events, proxy reads config + consumes inbound events"

  engine_version = "8.1"
  node_type      = "cache.t4g.micro"

  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  snapshot_retention_days = 1

  vpc_id             = module.vpc.vpc_id
  vpc_cidr_block     = module.vpc.vpc_cidr_block
  private_subnet_ids = module.vpc.private_subnet_ids

  tags = merge(local.tags, { "meandr:plane" = "config" })
}

# Local-module rename in state. The AWS replication_group_id also changes
# (`meandr-reader` → `meandr-config-stream`), so the underlying cluster
# gets destroyed and recreated — `moved` here just keeps the state-tree
# addressing consistent across the rename.
moved {
  from = module.config_valkey
  to   = module.config_stream
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

  vpc_id                 = module.vpc.vpc_id
  vpc_cidr_block         = module.vpc.vpc_cidr_block
  public_subnet_ids      = module.vpc.public_subnet_ids
  private_subnet_ids     = module.vpc.private_subnet_ids
  internal_dns_zone_id   = module.vpc.internal_dns_zone_id
  internal_dns_zone_name = module.vpc.internal_dns_zone_name

  config_writer_endpoint          = module.config_stream.primary_endpoint_address
  config_stream_security_group_id = module.config_stream.security_group_id

  # State-plane regions BE should consume streams from. Just our own
  # region today; expand when more regions come online with meandr-mcp.
  # event_writer_endpoints is positional with regions — first region's
  # event-stream writer, second region's, etc. In a multi-region prod
  # setup the extra regions' endpoints come via terraform_remote_state.
  regions                = [local.region]
  event_writer_endpoints = [module.mcp.event_writer_endpoint]

  db_instance_class = "db.t4g.micro"
  puma              = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 70 }
  jobs              = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 70 }
  ingest            = { cpu = 256, memory = 512, desired_count = 0 }
  migrate           = { cpu = 512, memory = 1024 }

  log_retention_days = 7
}

# --- meandr-mcp --------------------------------------------------------
#
# Proxy stack: writer Valkey + NLB + ECS cluster + proxy service. NLB has
# two plain TCP listeners (80 + 443) forwarding to proxy:8080; proxy
# terminates TLS itself once the BE-side cert pipeline lands (Phase 2).
# Customer HTTPS traffic won't work end-to-end until then — expected v0.

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
  public_subnet_ids      = module.vpc.public_subnet_ids
  private_subnet_ids     = module.vpc.private_subnet_ids
  internal_dns_zone_id   = module.vpc.internal_dns_zone_id
  internal_dns_zone_name = module.vpc.internal_dns_zone_name

  config_reader_endpoint = module.config_stream.reader_endpoint_address

  event_stream_node_type = "cache.t4g.micro"
  proxy                  = { cpu = 256, memory = 512, desired_count = 1, min_replicas = 1, max_replicas = 4, target_cpu_utilization = 60 }

  log_retention_days = 7
}

# --- Outputs -----------------------------------------------------------

output "vpc_id" { value = module.vpc.vpc_id }
output "vpc_cidr_block" { value = module.vpc.vpc_cidr_block }
output "public_subnet_ids" { value = module.vpc.public_subnet_ids }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }

output "config_stream_writer_endpoint" { value = module.config_stream.primary_endpoint_address }
output "config_stream_reader_endpoint" { value = module.config_stream.reader_endpoint_address }
output "event_stream_writer_endpoint" { value = module.mcp.event_writer_endpoint }

output "hostname" { value = module.api.hostname }
output "alb_dns_name" { value = module.api.alb_dns_name }
output "cluster_name" { value = module.api.cluster_name }
output "puma_service_name" { value = module.api.puma_service_name }
output "jobs_service_name" { value = module.api.jobs_service_name }
output "ingest_service_name" { value = module.api.ingest_service_name }
output "migrate_task_family" { value = module.api.migrate_task_family }
output "worker_sg_id" { value = module.api.worker_security_group_id }
output "rds_internal_dns_name" { value = module.api.rds_internal_dns_name }

output "mcp_cluster_name" { value = module.mcp.cluster_name }
output "mcp_proxy_service_name" { value = module.mcp.proxy_service_name }
output "mcp_nlb_dns_name" { value = module.mcp.nlb_dns_name }
