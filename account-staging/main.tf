provider "aws" {
  region  = "eu-central-1"
  profile = "meandr-staging"
}

# Global Accelerator's control plane exists ONLY in us-west-2 — accelerators,
# listeners, and endpoint groups for every other region are all created
# through this endpoint. Nothing about the accelerator runs there.
provider "aws" {
  alias   = "usw2"
  region  = "us-west-2"
  profile = "meandr-staging"
}

# meandr.live's public zone lives in the Shared account.
provider "aws" {
  alias   = "shared"
  region  = "eu-central-1"
  profile = "meandr-shared"
}

# One alias per region that runs a proxy. SSM parameters are regional with
# no replication, and a resource's provider must be a static reference — so
# adding a region adds an alias here and a parameter block below.
provider "aws" {
  alias   = "use1"
  region  = "us-east-1"
  profile = "meandr-staging"
}

locals {
  self_ips_param = "/meandr/staging/self-ips"
  regions_param  = "/meandr/staging/regions"

  # Every region running a proxy. Each already needs a provider alias above
  # and a self_ips block below, so this file is where the list has to live;
  # publishing it keeps CI from enumerating regions a second time.
  regions = ["eu-central-1", "us-east-1"]

  # Operational alarms, not billing. Same address today; split when there is
  # somewhere for on-call to route.
  alert_emails = ["aws-billing@meandr.com"]

  # The accelerator id is the CloudWatch dimension value, and it is the
  # listener arn's first path segment.
  ga_accelerator_id = split("/", module.global_accelerator.listener_arn)[1]

  account_tags = {
    "meandr:env"        = "staging"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
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
module "global_accelerator" {
  source = "../modules/global-accelerator"

  providers = {
    aws      = aws
    aws.usw2 = aws.usw2
    aws.dns  = aws.shared
  }

  env           = "staging"
  dns_zone_name = "meandr.live"

  tags = {
    "meandr:env"        = "staging"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# Our public ingress, written once per region because SSM parameters are
# regional and have no replication. Read by the proxy AND by BE, so both
# validate against the same string — if they disagreed, BE would accept an
# upstream the proxy refuses to dial.
# One per region, explicitly: a resource's provider must be a static
# reference, so adding a region adds a block here.
resource "aws_ssm_parameter" "self_ips_euc1" {
  name  = local.self_ips_param
  type  = "StringList"
  value = join(",", module.global_accelerator.static_ips)
  tags  = local.account_tags
}

resource "aws_ssm_parameter" "self_ips_use1" {
  provider = aws.use1

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

# Regions hardcode this arn, the same call made for acme_dns_role_arn:
# a literal keeps their only cross-stack dependency the provider alias.
#   terraform -chdir=account-staging output ga_listener_arn
output "ga_listener_arn" {
  description = "What a region attaches its endpoint group to."
  value       = module.global_accelerator.listener_arn
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

  name = "meandr-staging-ga-alerts"
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

  alarm_name        = "meandr-staging-ga-no-healthy-endpoints"
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

output "ga_alerts_topic_arn" {
  description = "Regions hardcode this for their per-endpoint-group alarm."
  value       = aws_sns_topic.ga_alerts.arn
}

output "ga_static_ips" {
  description = "Anycast pair. Stable for the accelerator's lifetime — safe for a customer allow-list, and what the proxy's SSRF dial guard must load as its self IPs."
  value       = module.global_accelerator.static_ips
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

# --- Cost-control guards (budget + anomaly detection) ------------------
#
# Daily budget with alert at 95% (ACTUAL only — DAILY budgets don't
# support FORECASTED per AWS). Notification only.
#
# Instance-size guard lives at the Org Root as an SCP — see
# account-master/main.tf §size_guard_scp. Member-account IAM-level
# guard was dropped in the same commit that landed the SCP.

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

# --- Read-only observer for the AWS MCP server --------------------------
#
# The AWS MCP server signs with SigV4, so it needs a long-lived access key
# — it cannot assume a role or use SSO. That makes this the ONLY static
# credential in the estate; everything else is roles, instance profiles
# and GitHub OIDC.
#
# STAGING ONLY, and deliberately so. ReadOnlyAccess is broad — it can read
# DynamoDB items and S3 objects, which in this account includes captured
# payloads. That is an accepted trade for being able to inspect the whole
# system; it would NOT be for production, which needs its own user with a
# policy narrowed to describe-and-metrics.
#
# The ACCESS KEY IS NOT MANAGED HERE. aws_iam_access_key writes the secret
# into Terraform state in plaintext, and state outlives the key. Mint it
# by hand and put it straight in the cred-store:
#
#   aws iam create-access-key --user-name meandr-mcp-observer --profile meandr-staging
#
# Rotation is manual for the same reason. IAM Access Analyzer and most
# SOC 2 checklists flag static keys by age, so this one is on the list to
# revisit — ideally by teaching the signer to assume a role instead.
resource "aws_iam_user" "mcp_observer" {
  name = "meandr-mcp-observer"
  path = "/mcp/"

  tags = {
    "meandr:env"        = "staging"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
    "meandr:purpose"    = "aws-mcp-server read-only observer"
  }
}

resource "aws_iam_user_policy_attachment" "mcp_observer_readonly" {
  user       = aws_iam_user.mcp_observer.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# --- Outputs ------------------------------------------------------------

output "mcp_observer_user_name" {
  description = "Mint this user's access key by hand — see the comment above; a Terraform-managed key would sit in state."
  value       = aws_iam_user.mcp_observer.name
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
