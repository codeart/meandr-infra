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

module "vpc" {
  source = "../../../modules/vpc"

  cidr_block = "10.10.0.0/16"
  azs        = ["eu-central-1a"] # single AZ for cost-sensitive staging; HA comes later if needed

  enable_nat        = true # staging has running workloads → NAT for egress / ECR pulls from private subnet
  internal_dns_zone = "staging.meandr.local"

  tags = {
    "meandr:env"        = "staging"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# --- Outputs (passthrough so downstream modules in this dir tree can read state) ---

output "vpc_id"               { value = module.vpc.vpc_id }
output "vpc_cidr_block"       { value = module.vpc.vpc_cidr_block }
output "public_subnet_ids"    { value = module.vpc.public_subnet_ids }
output "private_subnet_ids"   { value = module.vpc.private_subnet_ids }
output "internal_dns_zone_id" { value = module.vpc.internal_dns_zone_id }
output "internal_dns_zone_name" { value = module.vpc.internal_dns_zone_name }
output "azs"                  { value = module.vpc.azs }
