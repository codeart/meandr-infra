# Identical across environments. Everything that differs is in account.tf.

variable "github_org" {
  description = "GitHub org for trust policy scoping."
  type        = string
}

locals {
  self_ips_param = "/meandr/${local.env}/self-ips"
  regions_param  = "/meandr/${local.env}/regions"

  # The accelerator id is the CloudWatch dimension value, and it is the
  # listener arn's first path segment.
  ga_accelerator_id = split("/", module.global_accelerator.listener_arn)[1]

  account_tags = {
    "meandr:env"        = local.env
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

module "account_bootstrap" {
  source = "../modules/account-bootstrap"

  account_id = local.account_id
  github_org = var.github_org

  allowed_refs            = local.allowed_refs
  allowed_gh_environments = local.allowed_gh_environments

  tags = local.account_tags
}

# --- Global Accelerator -------------------------------------------------
#
# Here rather than in a region's state because it is ENV-GLOBAL and names
# no region. Putting it in the primary's state would make the primary own a
# resource every region depends on — the exact coupling the regional stacks
# were restructured to remove, and it would mean the primary's state file
# had to exist before any edge could serve traffic.
#
# It holds no list of regions either. Each region declares its own
# aws_globalaccelerator_endpoint_group against the listener arn below,
# pointing at its own NLB, so adding or removing a region never touches
# this file.
#
# Standing this up BEFORE a region is deliberate: with the accelerator
# present, that region's first apply creates an INTERNAL NLB and never has
# a public front door to migrate away from later. An NLB's scheme is
# immutable, so that migration is a replacement.
module "global_accelerator" {
  source = "../modules/global-accelerator"

  providers = {
    aws      = aws
    aws.usw2 = aws.usw2
    aws.dns  = aws.shared
  }

  env           = local.env
  dns_zone_name = local.proxy_apex

  tags = local.account_tags
}

# Read by CI to fan a deploy across every region. Written only here, in the
# env's primary region, because CI has one place to look before it knows
# where else to go.
#
# The per-region self_ips parameters are in account.tf: their providers must
# be static references, so they cannot loop over local.regions.
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

  name = "meandr-${local.env}-ga-alerts"
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

  alarm_name        = "meandr-${local.env}-ga-no-healthy-endpoints"
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

# --- Cost-control guards (budget + anomaly detection) --------------------
#
# Notification only; the "apply brakes" Lambda is deferred until there is
# real spend data to pick brake thresholds from.
#
# Instance-size guard lives at the Org Root as an SCP — see
# account-master/main.tf §size_guard_scp. The member-account IAM-level
# guard was dropped in the same commit that landed the SCP.

module "daily_budget" {
  source = "../modules/aws-budget"

  name                = "meandr-${local.env}-daily"
  amount_usd          = local.budget_usd
  time_unit           = "DAILY"
  threshold_percents  = local.budget_thresholds
  notification_emails = ["aws-billing@meandr.com"]

  tags = local.account_tags
}

# ML spike alerts alongside the daily budget, on the same SNS topic. Fires
# within minutes rather than waiting for a daily total to cross a line.
module "cost_anomaly" {
  source = "../modules/aws-cost-anomaly"

  name          = "meandr-${local.env}"
  threshold_usd = local.anomaly_usd
  sns_topic_arn = module.daily_budget.sns_topic_arn

  tags = local.account_tags
}

# --- Outputs ------------------------------------------------------------

# Regions hardcode these arns, the same call made for acme_dns_role_arn:
# a literal keeps their only cross-stack dependency the provider alias.
#   terraform -chdir=account-<env> output ga_listener_arn

output "ga_listener_arn" {
  description = "What a region attaches its endpoint group to."
  value       = module.global_accelerator.listener_arn
}

output "ga_alerts_topic_arn" {
  description = "Regions hardcode this for their per-endpoint-group alarm."
  value       = aws_sns_topic.ga_alerts.arn
}

output "ga_static_ips" {
  description = "Anycast pair. Stable for the accelerator's lifetime — safe for a customer allow-list, and what the proxy's SSRF dial guard must load as its self IPs."
  value       = module.global_accelerator.static_ips
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
