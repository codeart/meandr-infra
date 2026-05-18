# Shared account — runtime resources used across every environment.
#
# Currently houses:
#   - GitHub OIDC provider (one per account that has CI deploys)
#   - IAM roles for CI: ECR push, Terraform infra-deploy
#   - ECR repos for each service
#   - ECR cross-region replication (eu-central-1 → us-east-1)
#
# Route 53 is managed manually by the operator — see ../README.md notes.
# ACM certs live in workload accounts per region (not here).

provider "aws" {
  region = var.region
}

# Sanity guard — apply must run in the Shared account.
data "aws_caller_identity" "current" {}

locals {
  shared_account_id = "303529433558"
}

resource "null_resource" "account_guard" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == local.shared_account_id
      error_message = "shared/ must run in the Shared account (${local.shared_account_id}). Current account: ${data.aws_caller_identity.current.account_id}."
    }
  }
}
