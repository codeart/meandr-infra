provider "aws" {
  region  = "eu-central-1"
  profile = "meandr-staging"
}

variable "github_org" {
  description = "GitHub org for trust policy scoping."
  type        = string
}

module "account_bootstrap" {
  source = "../modules/account-bootstrap"

  account_id = "259534890849" # Staging
  github_org = var.github_org

  # Staging trusts develop + main from image-pushing repos.
  # `staging` GH Environment is also trusted — workflow jobs use it to scope
  # secrets/vars and (optionally) add reviewer gates. When a job sets
  # `environment: staging`, GitHub OIDC sends an environment-based subject
  # claim instead of a ref-based one; both forms must be in the allow list.
  allowed_refs = [
    "refs/heads/main",
    "refs/heads/develop",
  ]
  allowed_gh_environments = [
    "staging",
  ]

  tags = {
    "meandr:env"        = "staging"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# --- Cost-control guards (alerts + IAM size-guard) ---------------------
#
# Daily budget with alert at 95% (ACTUAL only — DAILY budgets don't
# support FORECASTED per AWS). Notification
# only; no Lambda/SCP actions wired. See `project_budget_alerts.md`
# memory for the cross-env design.

module "daily_budget" {
  source = "../modules/aws-budget"

  name                = "meandr-staging-daily"
  amount_usd          = 25
  time_unit           = "DAILY"
  threshold_percents  = [95]
  notification_emails = ["aws-billing@meandr.com"]

  tags = {
    "meandr:env"        = "staging"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# Deny RunInstances / RDS-Create / ElastiCache-Create on giant instance
# types from the gh-actions-deploy role. Catches fat-finger node-type
# typos in TF before they reach AWS.
module "size_guard" {
  source = "../modules/iam-instance-size-guard"

  name = "meandr-staging-size-guard"
}

resource "aws_iam_role_policy_attachment" "deploy_size_guard" {
  role       = module.account_bootstrap.gh_actions_deploy_role_name
  policy_arn = module.size_guard.policy_arn
}

# Cost Anomaly Detection — ML spike alerts in addition to the daily
# budget. $10/day deviation threshold; fires within minutes via the
# same SNS topic as the budget.
module "cost_anomaly" {
  source = "../modules/aws-cost-anomaly"

  name          = "meandr-staging"
  threshold_usd = 10
  sns_topic_arn = module.daily_budget.sns_topic_arn

  tags = {
    "meandr:env"        = "staging"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# --- Outputs ------------------------------------------------------------

output "github_oidc_provider_arn" {
  value = module.account_bootstrap.github_oidc_provider_arn
}

output "gh_actions_deploy_role_arn" {
  value = module.account_bootstrap.gh_actions_deploy_role_arn
}

output "daily_budget_sns_topic_arn" {
  description = "SNS topic that the daily budget publishes to. Subscribe more channels (Slack, PagerDuty) here without touching the budget."
  value       = module.daily_budget.sns_topic_arn
}
