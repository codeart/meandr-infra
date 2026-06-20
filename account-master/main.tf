# Admin Master account — Organizations root, consolidated billing, no
# workloads. The cost-control resources here aggregate across every
# child account + catch master-only line items (Support tier, Tax,
# Marketplace, RI/SP pool) that don't show on any single child's bill.
#
# Defense-in-depth against a compromised key spinning up bitcoin
# miners (real story: a former client got hit for $50k over several
# months because the bills went to a corporate inbox nobody read).
# Layered alerting:
#
#   - Cost Anomaly Detection (IMMEDIATE, ~minutes)  ← fastest signal
#   - CloudWatch billing alarm     (~6h refresh)    ← absolute ceiling
#   - DAILY budget                 (8-24h trail)    ← daily total
#   - MONTHLY budget + FORECASTED  (same-day proj.) ← slow-creep + trend
#
# Account ID + profile name documented in infra_inventory.md §2.
# us-east-1 region because AWS billing metrics + Cost Anomaly Detection
# only publish to us-east-1.

provider "aws" {
  region  = "us-east-1"
  profile = "meandr-master"
}

locals {
  account_id = "018504832279" # Admin Master

  tags = {
    "meandr:env"        = "master"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }

  notification_emails = ["aws-billing@meandr.com"]
}

# --- Account guard ------------------------------------------------------

data "aws_caller_identity" "current" {}

resource "null_resource" "account_guard" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == local.account_id
      error_message = "Account mismatch: expected ${local.account_id}, got ${data.aws_caller_identity.current.account_id}. Wrong AWS_PROFILE? Expected meandr-master."
    }
  }
}

# --- Daily budget — sum-of-children + buffer ---------------------------
#
# $200/day: per-env dailies total $140 (dev $15 + staging $25 + prod
# $100), plus headroom for master-only costs (Support, Tax) + a buffer
# for the case where one child env is at-or-near its own daily ceiling.
# ACTUAL only — DAILY budgets don't support FORECASTED per AWS.

module "daily_budget" {
  source = "../modules/aws-budget"

  name                = "meandr-master-daily"
  amount_usd          = 200
  time_unit           = "DAILY"
  threshold_percents  = [95]
  notification_emails = local.notification_emails

  tags = local.tags
}

# --- Monthly budget — slow-creep + forecast ----------------------------
#
# $1,500/month. Current run-rate is ~$200/month so this is generous;
# the goal is to catch "something is genuinely broken" without
# spamming on the natural growth from real customer traffic.
# Tiered alerts (50/75/95/100) at MONTHLY mean FORECASTED is allowed,
# so we get both ACTUAL crossings AND same-day projections that "at
# current pace you'll hit $X by month-end" — the most useful signal
# for catching slow drift.

module "monthly_budget" {
  source = "../modules/aws-budget"

  name                = "meandr-master-monthly"
  amount_usd          = 1500
  time_unit           = "MONTHLY"
  threshold_percents  = [50, 75, 95, 100]
  notification_emails = local.notification_emails

  tags = local.tags
}

# --- CloudWatch billing alarm — hard tripwire --------------------------
#
# `EstimatedCharges` is published to AWS/Billing in us-east-1 only,
# updated approximately every 6 hours. Fires when current-month
# accumulated charges cross $500 — the "current month is already
# broken" signal that's faster than the 100% monthly budget breach
# (which only fires at $1500) but slower than anomaly detection
# (which fires on rate-of-change, not total).
#
# Reuses the daily budget's SNS topic so all cost alerts land in the
# same inbox.

resource "aws_cloudwatch_metric_alarm" "current_month_total" {
  alarm_name        = "meandr-master-current-month-total"
  alarm_description = "Current-month EstimatedCharges across the organization crossed $500. Compromise tripwire — investigate via Cost Explorer (Linked Account dimension) to find the source."

  namespace           = "AWS/Billing"
  metric_name         = "EstimatedCharges"
  statistic           = "Maximum"
  period              = 21600 # 6h — matches AWS's publish cadence
  evaluation_periods  = 1
  threshold           = 500
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    Currency = "USD"
  }

  alarm_actions = [module.daily_budget.sns_topic_arn]
  ok_actions    = [module.daily_budget.sns_topic_arn]

  treat_missing_data = "notBreaching"

  tags = local.tags
}

# --- Cost Anomaly Detection — ML spike detection -----------------------
#
# Threshold higher than per-env ($30 vs $5/$10/$20) because the master
# sees aggregate spend across every child account — natural variation
# is louder. SERVICE dimension catches "service X spiked across the
# org"; if we want "child account Y spiked" granularity later we can
# add a second monitor with monitor_dimension = "LINKED_ACCOUNT".

module "cost_anomaly" {
  source = "../modules/aws-cost-anomaly"

  name          = "meandr-master"
  threshold_usd = 30
  sns_topic_arn = module.daily_budget.sns_topic_arn

  tags = local.tags
}

# --- Org-wide instance-size guard (SCP) --------------------------------
#
# Service Control Policy denying RunInstances + RDS Create/Modify +
# ElastiCache Create/Modify when the requested instance/node type matches
# a "giant" pattern. Attached to the Root, so every member account
# (dev/staging/production) inherits the deny — no principal in those
# accounts can launch a giant instance, full stop.
#
# Master itself is exempt (SCPs cannot constrain the Organizations
# management account by design); the per-env iam-instance-size-guard
# module attachments stay in place during rollout as defense-in-depth,
# and can be removed in a follow-up once we're confident in SCP behavior.
#
# Override model deferred: if a real need ever surfaces, the choices are
# (a) edit the pattern lists + re-apply, or (b) detach the SCP from the
# target in the Organizations console (CloudTrail captures the detach).
# We'll design a proper break-glass role only when an actual workload
# needs it — premature today.
#
# Bootstrap (one-time, already done): the master must enable
# SERVICE_CONTROL_POLICY on the Root before any policy can attach:
#   aws organizations enable-policy-type \
#     --root-id r-9zq7 --policy-type SERVICE_CONTROL_POLICY \
#     --profile meandr-master

module "size_guard_scp" {
  source = "../modules/org-scp-instance-size-guard"

  name       = "meandr-deny-large-instances"
  target_ids = ["r-9zq7"] # Org Root — applies to dev + staging + production

  tags = local.tags
}

# --- Outputs ------------------------------------------------------------

output "account_id" {
  description = "Master account ID. Cross-references infra_inventory.md §2."
  value       = local.account_id
}

output "size_guard_scp_id" {
  description = "Organizations policy ID for the org-wide size-guard SCP. Useful for `aws organizations list-targets-for-policy --policy-id <id>` to audit current attachments."
  value       = module.size_guard_scp.policy_id
}

output "daily_budget_sns_topic_arn" {
  description = "SNS topic that ALL master-level cost alerts publish to (daily budget, monthly budget, CloudWatch billing alarm, anomaly detection). Subscribe more channels (Slack, PagerDuty) here without touching the budgets/alarms themselves."
  value       = module.daily_budget.sns_topic_arn
}

output "current_month_total_alarm_arn" {
  description = "ARN of the CloudWatch billing alarm. Useful for CLI diagnostic commands (`aws cloudwatch describe-alarms`)."
  value       = aws_cloudwatch_metric_alarm.current_month_total.arn
}
