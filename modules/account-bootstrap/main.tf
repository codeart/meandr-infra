# account-bootstrap — module called from each workload account directory
# (staging-account/, production-account/, …).
#
# Creates the per-account plumbing CI needs to deploy:
#   - GitHub OIDC provider in this account
#   - IAM role `gh-actions-deploy` scoped to ECS service updates only
#
# Workload resources (VPC, ECS cluster, task defs, etc.) live in the
# per-region module under <env>/<region>/. This module is account-scope.

# Sanity guard — apply must run in the expected account.
data "aws_caller_identity" "current" {}

resource "null_resource" "account_guard" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.account_id
      error_message = "Expected account ${var.account_id}, got ${data.aws_caller_identity.current.account_id}. Wrong AWS_PROFILE?"
    }
  }
}
