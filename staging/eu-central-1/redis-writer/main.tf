provider "aws" {
  region  = "eu-central-1"
  profile = "meandr-staging"
}

# Sanity guard — applies must run in the Staging account.
data "aws_caller_identity" "current" {}

resource "null_resource" "account_guard" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == "259534890849"
      error_message = "Expected Staging account (259534890849). Wrong AWS_PROFILE?"
    }
  }
}

data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket  = "meandr-tfstate-shared"
    key     = "staging/eu-central-1/vpc/terraform.tfstate"
    region  = "eu-central-1"
    profile = "meandr-shared"
  }
}

# Writer Valkey — source of truth for config writes from meandr-api. Streams
# invalidations on `inv` to the reader cluster. Single-region by design (writer
# is never in a Global Datastore) so transit_encryption is OFF — keeps client
# config simpler and avoids the TLS cert plumbing on the BE side.
module "redis_writer" {
  source = "../../../modules/elasticache-valkey"

  name        = "meandr-writer"
  description = "Writer Valkey staging - meandr-api writes config records here"
  role        = "writer"

  engine_version = "8.1"
  node_type      = "cache.t4g.micro"

  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  transit_encryption_enabled = false
  at_rest_encryption_enabled = true

  snapshot_retention_days = 1

  vpc_id                 = data.terraform_remote_state.vpc.outputs.vpc_id
  vpc_cidr_block         = data.terraform_remote_state.vpc.outputs.vpc_cidr_block
  private_subnet_ids     = data.terraform_remote_state.vpc.outputs.private_subnet_ids
  internal_dns_zone_id   = data.terraform_remote_state.vpc.outputs.internal_dns_zone_id
  internal_dns_zone_name = data.terraform_remote_state.vpc.outputs.internal_dns_zone_name

  tags = {
    "meandr:env"        = "staging"
    "meandr:role"       = "writer"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# --- Outputs -------------------------------------------------------------

output "primary_endpoint_address"   { value = module.redis_writer.primary_endpoint_address }
output "internal_dns_name"          { value = module.redis_writer.internal_dns_name }
output "security_group_id"          { value = module.redis_writer.security_group_id }
output "transit_encryption_enabled" { value = module.redis_writer.transit_encryption_enabled }
output "engine_version"             { value = module.redis_writer.engine_version }
