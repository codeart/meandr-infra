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

# Read VPC outputs from the vpc module's state.
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket  = "meandr-tfstate-shared"
    key     = "staging/eu-central-1/vpc/terraform.tfstate"
    region  = "eu-central-1"
    profile = "meandr-shared"
  }
}

module "rds" {
  source = "../../../modules/rds-postgres"

  name           = "meandr-api"
  db_name        = "meandr_staging"
  engine_version = "18.4"

  # Staging baseline. Bump to db.t4g.small if migrations get slow.
  instance_class           = "db.t4g.micro"
  allocated_storage_gb     = 20
  max_allocated_storage_gb = 100

  multi_az              = false
  backup_retention_days = 7

  # Staging is destroyable; skip final snapshot + no deletion protection so
  # `terraform destroy` works without ceremony.
  deletion_protection = false
  skip_final_snapshot = true

  vpc_id                 = data.terraform_remote_state.vpc.outputs.vpc_id
  vpc_cidr_block         = data.terraform_remote_state.vpc.outputs.vpc_cidr_block
  private_subnet_ids     = data.terraform_remote_state.vpc.outputs.private_subnet_ids
  internal_dns_zone_id   = data.terraform_remote_state.vpc.outputs.internal_dns_zone_id
  internal_dns_zone_name = data.terraform_remote_state.vpc.outputs.internal_dns_zone_name

  secret_name = "meandr/db/staging/master"

  tags = {
    "meandr:env"        = "staging"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# --- Outputs -------------------------------------------------------------

output "instance_id"       { value = module.rds.instance_id }
output "endpoint"          { value = module.rds.endpoint }
output "internal_dns_name" { value = module.rds.internal_dns_name }
output "security_group_id" { value = module.rds.security_group_id }
output "secret_arn"        { value = module.rds.secret_arn }
output "db_name"           { value = module.rds.db_name }
