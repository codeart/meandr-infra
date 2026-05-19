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

# Reader Valkey — what the proxy reads from. TLS-in-transit is ON so we can add
# a Global Datastore secondary later without rebuild. Note that T-family is NOT
# eligible for GD; when production reader is built we'll pick cache.r7g.large
# or m7g.large. For staging single-region, t4g.micro is fine.
module "redis_reader" {
  source = "../../../modules/elasticache-valkey"

  name        = "meandr-reader"
  description = "Reader Valkey staging - proxy reads config records here"
  role        = "reader"

  engine_version = "8.1"
  node_type      = "cache.t4g.micro"

  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  # GD-readiness: TLS must be on from day one. Cannot be toggled in place.
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  snapshot_retention_days = 1

  vpc_id                 = data.terraform_remote_state.vpc.outputs.vpc_id
  vpc_cidr_block         = data.terraform_remote_state.vpc.outputs.vpc_cidr_block
  private_subnet_ids     = data.terraform_remote_state.vpc.outputs.private_subnet_ids
  internal_dns_zone_id   = data.terraform_remote_state.vpc.outputs.internal_dns_zone_id
  internal_dns_zone_name = data.terraform_remote_state.vpc.outputs.internal_dns_zone_name

  tags = {
    "meandr:env"        = "staging"
    "meandr:role"       = "reader"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# --- Outputs -------------------------------------------------------------

output "primary_endpoint_address"   { value = module.redis_reader.primary_endpoint_address }
output "reader_endpoint_address"    { value = module.redis_reader.reader_endpoint_address }
output "internal_dns_name"          { value = module.redis_reader.internal_dns_name }
output "security_group_id"          { value = module.redis_reader.security_group_id }
output "transit_encryption_enabled" { value = module.redis_reader.transit_encryption_enabled }
output "engine_version"             { value = module.redis_reader.engine_version }
