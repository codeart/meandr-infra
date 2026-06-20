provider "aws" {
  region  = "eu-central-1"
  profile = "meandr-development"
}

locals {
  account_id = "238020582774" # Development

  tags = {
    "meandr:env"        = "development"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# --- Account guard ------------------------------------------------------
#
# Same pattern as the regional callers: precondition fails loudly if the
# caller's identity doesn't match the expected dev account. Prevents an
# `apply` from accidentally landing in staging or production.

data "aws_caller_identity" "current" {}

resource "null_resource" "account_guard" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == local.account_id
      error_message = "Account mismatch: expected ${local.account_id}, got ${data.aws_caller_identity.current.account_id}. Wrong AWS_PROFILE?"
    }
  }
}

# --- Dev IAM user (account-level identity) ------------------------------
#
# Long-lived access key used by engineers running the BE locally during
# the auth-development phase. This file holds account-level resources
# only — the user identity, its access key, and the SM scope that
# mirrors the production task role.
#
# Region-bound resources (cred-store Dynamo table, KMS CMK) and the
# IAM grants tying them to this user live in `development/eu-central-1/`,
# matching the account-staging / staging-eu-central-1 split.
#
# Rotation: there's no automation. If a key leaks or an engineer
# offboards, run `terraform taint aws_iam_access_key.dev` + apply.
# Re-running apply mints a fresh key and the old one is destroyed.
#
# Why an IAM user and not SSO?
#   - The BE process needs static credentials in `~/.aws/credentials`
#     or env vars. SSO sessions expire on an hourly cadence and would
#     break long-running dev work.
#   - Scoping is wide enough (one account, one namespace) that the
#     blast radius is bounded even if the key leaks.

resource "aws_iam_user" "dev" {
  name = "meandr-dev"
  path = "/dev/"

  tags = merge(local.tags, {
    Name    = "meandr-dev"
    Purpose = "Local-dev access to AWS for auth work"
  })
}

resource "aws_iam_user_policy" "dev_secretsmanager" {
  name = "secrets-manager-access"
  user = aws_iam_user.dev.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Mirrors the ECS task role's tenant-secrets policy (see
      # modules/meandr-api/main.tf): full CRUD on meandr/tenants/*.
      # Same actions, same resource shape — so behavior verified
      # against the dev key behaves the same on prod task identity.
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecret",
          "secretsmanager:DeleteSecret",
          "secretsmanager:TagResource",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "arn:aws:secretsmanager:*:${local.account_id}:secret:meandr/tenants/*"
      },
      # ListSecrets doesn't support resource-level scoping in IAM; the
      # task role grants it on * for the same reason.
      {
        Effect   = "Allow"
        Action   = "secretsmanager:ListSecrets"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_access_key" "dev" {
  user = aws_iam_user.dev.name

  # No PGP key — Terraform stores the secret in state (encrypted at
  # rest via the S3 backend's KMS key). Retrieve once via
  # `terraform output -raw dev_secret_access_key`; copy into
  # ~/.aws/credentials or .env locally.
}

# --- Cost-control guards (budget + anomaly detection) ------------------
#
# Daily budget with alert at 95% (ACTUAL only — DAILY budgets don't
# support FORECASTED per AWS). $15/day caps the "I left a test cluster
# running over the weekend" failure mode without spamming on normal
# dev iteration. Notification only.
#
# Instance-size guard lives at the Org Root as an SCP — see
# account-master/main.tf §size_guard_scp. Member-account IAM-level
# guard was dropped in the same commit that landed the SCP.

module "daily_budget" {
  source = "../modules/aws-budget"

  name                = "meandr-development-daily"
  amount_usd          = 15
  time_unit           = "DAILY"
  threshold_percents  = [95]
  notification_emails = ["aws-billing@meandr.com"]

  tags = local.tags
}

# Cost Anomaly Detection — ML spike detection on top of the daily
# budget. Fires within minutes when a service's actual spend exceeds
# the ML-predicted baseline by $5 (catches the "something went 10×
# at noon" case that the daily budget would miss until the next day).
# Publishes to the same SNS topic as the daily budget.
module "cost_anomaly" {
  source = "../modules/aws-cost-anomaly"

  name          = "meandr-development"
  threshold_usd = 5
  sns_topic_arn = module.daily_budget.sns_topic_arn

  tags = local.tags
}

# --- Outputs ------------------------------------------------------------

output "dev_user_arn" {
  description = "ARN of the meandr-dev IAM user."
  value       = aws_iam_user.dev.arn
}

output "daily_budget_sns_topic_arn" {
  description = "SNS topic that the daily budget publishes to. Subscribe more channels (Slack, PagerDuty) here without touching the budget."
  value       = module.daily_budget.sns_topic_arn
}

output "dev_user_name" {
  description = "Name of the meandr-dev IAM user. Region callers under `development/<region>/` look this up via data source to attach region-scoped policies."
  value       = aws_iam_user.dev.name
}

output "dev_access_key_id" {
  description = "AWS_ACCESS_KEY_ID for the meandr-dev user."
  value       = aws_iam_access_key.dev.id
}

output "dev_secret_access_key" {
  description = "AWS_SECRET_ACCESS_KEY for the meandr-dev user. Retrieve once with `terraform output -raw dev_secret_access_key`."
  value       = aws_iam_access_key.dev.secret
  sensitive   = true
}
