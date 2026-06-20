provider "aws" {
  region  = "us-east-1"
  profile = "meandr-production"
}

variable "github_org" {
  description = "GitHub org for trust policy scoping."
  type        = string
}

module "account_bootstrap" {
  source = "../modules/account-bootstrap"

  account_id = "393686273464" # Production
  github_org = var.github_org

  # Production only trusts:
  #   - main branch of trusted repos (the "production-track" branch), AND
  #   - GH Actions Environment "production" (with required reviewers configured in GH)
  # The combination means: a deploy needs both a green main + a human approval.
  allowed_refs = [
    "refs/heads/main",
  ]
  allowed_gh_environments = [
    "production",
  ]

  tags = {
    "meandr:env"        = "production"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# --- Cost-control guards (alerts + IAM size-guard) ---------------------
#
# Production gets a tiered budget — 50% / 75% / 95% / 100% gives both
# the early heads-up (50%) and the holy-shit signal (100%) without
# spamming on every small percentage move. ACTUAL-only since this is
# a DAILY budget (AWS rejects FORECASTED on daily, per the variable
# doc in modules/aws-budget). Four notifications max per day worst case.
# Notification only; the "apply brakes" Lambda is deferred per memory
# `project_budget_alerts.md` until we have a week of real spend data
# to pick the brake thresholds from.

module "daily_budget" {
  source = "../modules/aws-budget"

  name                = "meandr-production-daily"
  amount_usd          = 100
  time_unit           = "DAILY"
  threshold_percents  = [50, 75, 95, 100]
  notification_emails = ["aws-operations@meandr.com"]

  tags = {
    "meandr:env"        = "production"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

module "size_guard" {
  source = "../modules/iam-instance-size-guard"

  name = "meandr-production-size-guard"
}

resource "aws_iam_role_policy_attachment" "deploy_size_guard" {
  role       = module.account_bootstrap.gh_actions_deploy_role_name
  policy_arn = module.size_guard.policy_arn
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
