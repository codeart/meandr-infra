provider "aws" {
  region  = "us-east-1"
  profile = "meandr-production"
}

# Global Accelerator's control plane exists ONLY in us-west-2, whatever
# region the endpoints live in. Nothing about the accelerator runs there.
provider "aws" {
  alias   = "usw2"
  region  = "us-west-2"
  profile = "meandr-production"
}

# The public zones live in the Shared account — ACM DNS validation and the
# public hostname records.
provider "aws" {
  alias   = "shared"
  region  = "eu-central-1"
  profile = "meandr-shared"
}

variable "github_org" {
  description = "GitHub org for trust policy scoping."
  type        = string
}

locals {
  self_ips_param = "/meandr/production/self-ips"
  regions_param  = "/meandr/production/regions"

  # Every region running a proxy. Each also needs a provider alias above
  # and a self_ips block below, so this file is where the list has to live;
  # publishing it keeps CI from enumerating regions a second time.
  regions = ["us-east-1"]

  # Operational alarms, not billing — aws-billing stays on the budget and
  # cost-anomaly topics.
  alert_emails = ["aws-prd@meandr.com"]

  # The accelerator id is the CloudWatch dimension value, and it is the
  # listener arn's first path segment.
  ga_accelerator_id = split("/", module.global_accelerator.listener_arn)[1]

  account_tags = {
    "meandr:env"        = "production"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
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

# --- Cost-control guards (budget + anomaly detection) ------------------
#
# Production gets a tiered budget — 50% / 75% / 95% / 100% gives both
# the early heads-up (50%) and the holy-shit signal (100%) without
# spamming on every small percentage move. ACTUAL-only since this is
# a DAILY budget (AWS rejects FORECASTED on daily, per the variable
# doc in modules/aws-budget). Four notifications max per day worst case.
# Notification only; the "apply brakes" Lambda is deferred per memory
# `project_budget_alerts.md` until we have a week of real spend data
# to pick the brake thresholds from.
#
# Instance-size guard lives at the Org Root as an SCP — see
# account-master/main.tf §size_guard_scp. Member-account IAM-level
# guard was dropped in the same commit that landed the SCP.

module "daily_budget" {
  source = "../modules/aws-budget"

  name                = "meandr-production-daily"
  amount_usd          = 100
  time_unit           = "DAILY"
  threshold_percents  = [50, 75, 95, 100]
  notification_emails = ["aws-billing@meandr.com"]

  tags = {
    "meandr:env"        = "production"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# Cost Anomaly Detection — ML spike alerts in addition to the daily
# budget. $20/day deviation threshold (higher than dev/staging because
# production has real traffic-driven variation, lower threshold would
# alert on legitimate weekend → Monday spikes). Fires within minutes
# via the same SNS topic as the budget.
module "cost_anomaly" {
  source = "../modules/aws-cost-anomaly"

  name          = "meandr-production"
  threshold_usd = 20
  sns_topic_arn = module.daily_budget.sns_topic_arn

  tags = {
    "meandr:env"        = "production"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# --- Global Accelerator -------------------------------------------------
#
# Here rather than in a region's state because it is ENV-GLOBAL and names
# no region. Putting it in the primary's state would make the primary own a
# resource every region depends on — the exact coupling the regional stacks
# were restructured to remove.
#
# It holds no list of regions either. Each region declares its own
# aws_globalaccelerator_endpoint_group against the listener arn below,
# pointing at its own NLB, so adding or removing a region never touches
# this file.
#
# Standing this up BEFORE the region is deliberate: with the accelerator
# present, production's first apply creates an INTERNAL NLB and never has
# a public front door to migrate away from later. Staging had to do that
# migration; production does not.
module "global_accelerator" {
  source = "../modules/global-accelerator"

  providers = {
    aws      = aws
    aws.usw2 = aws.usw2
    aws.dns  = aws.shared
  }

  env           = "production"
  dns_zone_name = "meandr.io"

  tags = local.account_tags
}

# Our public ingress, written once per region because SSM parameters are
# regional and have no replication. Read by the proxy AND by BE, so both
# validate against the same string — if they disagreed, BE would accept an
# upstream the proxy refuses to dial.
resource "aws_ssm_parameter" "self_ips_use1" {
  name  = local.self_ips_param
  type  = "StringList"
  value = join(",", module.global_accelerator.static_ips)
  tags  = local.account_tags
}

# Read by CI to fan a deploy across every region. Written only here, in the
# env's primary region, because CI has one place to look before it knows
# where else to go.
resource "aws_ssm_parameter" "regions" {
  name  = local.regions_param
  type  = "StringList"
  value = join(",", local.regions)
  tags  = local.account_tags
}

# --- Accelerator alerting -----------------------------------------------
#
# In us-west-2 because GA publishes its metrics there with its control
# plane, and an alarm can only notify a topic in its own region.
#
# Regions attach their own per-endpoint-group alarm to this topic, so it
# names no region — same inversion as the listener above.

resource "aws_sns_topic" "ga_alerts" {
  provider = aws.usw2

  name = "meandr-production-ga-alerts"
  tags = local.account_tags
}

resource "aws_sns_topic_subscription" "ga_alerts" {
  provider = aws.usw2
  for_each = toset(local.alert_emails)

  topic_arn = aws_sns_topic.ga_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# Zero healthy endpoints ACROSS ALL REGIONS is a different incident from one
# region dropping: with nothing healthy, GA stops withdrawing and routes to
# every endpoint instead, so traffic keeps arriving at dead regions.
resource "aws_cloudwatch_metric_alarm" "ga_no_healthy_endpoints" {
  provider = aws.usw2

  alarm_name        = "meandr-production-ga-no-healthy-endpoints"
  alarm_description = "Global Accelerator has no healthy endpoint in any region; it is now failing open to all of them."

  namespace   = "AWS/GlobalAccelerator"
  metric_name = "HealthyEndpointCount"
  dimensions  = { Accelerator = local.ga_accelerator_id }

  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2

  # Silence is the failure being alarmed on, so absent data is not healthy.
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.ga_alerts.arn]
  ok_actions    = [aws_sns_topic.ga_alerts.arn]
  tags          = local.account_tags
}

# --- Outputs ------------------------------------------------------------

# Regions hardcode these arns, the same call made for acme_dns_role_arn:
# a literal keeps their only cross-stack dependency the provider alias.
#   terraform -chdir=account-production output ga_listener_arn
output "ga_listener_arn" {
  description = "What a region attaches its endpoint group to."
  value       = module.global_accelerator.listener_arn
}

output "ga_static_ips" {
  description = "Anycast pair. Stable for the accelerator's lifetime — safe for a customer allow-list, and what the proxy's SSRF dial guard must load as its self IPs."
  value       = module.global_accelerator.static_ips
}

output "ga_alerts_topic_arn" {
  description = "Regions hardcode this for their per-endpoint-group alarm."
  value       = aws_sns_topic.ga_alerts.arn
}

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
