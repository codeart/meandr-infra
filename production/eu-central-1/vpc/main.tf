provider "aws" {
  region  = "eu-central-1"
  profile = "meandr-production"
}

# Sanity guard — applies must run in the Production account.
data "aws_caller_identity" "current" {}

resource "null_resource" "account_guard" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == "393686273464"
      error_message = "Expected Production account (393686273464). Wrong AWS_PROFILE?"
    }
  }
}

module "vpc" {
  source = "../../../modules/vpc"

  # Different /16 from staging to keep VPC-peering safe in the future.
  cidr_block = "10.20.0.0/16"

  # Two AZs
  azs = ["eu-central-1a", "eu-central-1b"]

  enable_nat        = false # disabled for now
  internal_dns_zone = "production.meandr.local"

  tags = {
    "meandr:env"        = "production"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# --- Outputs (passthrough so downstream modules in this dir tree can read state) ---

output "vpc_id"                 { value = module.vpc.vpc_id }
output "vpc_cidr_block"         { value = module.vpc.vpc_cidr_block }
output "public_subnet_ids"      { value = module.vpc.public_subnet_ids }
output "private_subnet_ids"     { value = module.vpc.private_subnet_ids }
output "internal_dns_zone_id"   { value = module.vpc.internal_dns_zone_id }
output "internal_dns_zone_name" { value = module.vpc.internal_dns_zone_name }
output "azs"                    { value = module.vpc.azs }
output "nat_enabled"            { value = module.vpc.nat_enabled }
