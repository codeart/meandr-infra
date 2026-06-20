# AWS Budgets with email notifications.
#
# Each threshold percentage in var.threshold_percents creates TWO
# notifications: one FORECASTED (AWS projects you'll cross by period
# end — fires same-day, the early-warning signal), and one ACTUAL
# (spend literally crossed the line, 8-24h lag in Cost Explorer data
# — the confirmation signal). Both notify the same SNS topic + email
# list; downstream you only ever see one of the two for a given
# crossing because we configure both to also send the email directly.
#
# Why SNS topic AND direct email both:
#   - Email: zero ops, lands in your inbox.
#   - SNS topic: forward-compat seam — if you ever want Slack / PagerDuty
#     / Lambda-driven brakes on top, you add the subscription, no
#     budget reconfigure needed. Today nothing else subscribes.
#
# Budget Actions (the IAM-policy-attach kind) are NOT wired here —
# notifications only per our design (see docs sweep + memory). Add
# aws_budgets_budget_action separately in the consuming caller if the
# decision ever flips.

data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "budget_alerts" {
  name = "${var.name}-budget-alerts"
  tags = var.tags
}

# AWS Budgets is a Budget Action; the SNS topic needs a policy
# allowing the budgets service principal to Publish to it. Without this,
# the budget notification fires but SNS rejects the publish silently.
resource "aws_sns_topic_policy" "budgets_publish" {
  arn = aws_sns_topic.budget_alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "budgets.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.budget_alerts.arn
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "emails" {
  for_each = toset(var.notification_emails)

  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# Single budget per call site. The notification block is dynamic so a
# caller passing [50, 75, 95, 100] gets 8 notifications; a caller
# passing [95] gets 2.
resource "aws_budgets_budget" "main" {
  name         = var.name
  budget_type  = "COST"
  limit_amount = tostring(var.amount_usd)
  limit_unit   = "USD"
  time_unit    = var.time_unit

  # The required cost_filter is omitted — budget scopes to all costs in
  # the account. Could narrow by service/tag later if we want to alert
  # on "the proxy specifically is expensive" vs "the whole account is."

  dynamic "notification" {
    for_each = var.threshold_percents
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.notification_emails
      subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
    }
  }

  # FORECASTED notifications are only supported on MONTHLY+ budgets;
  # AWS rejects them on DAILY budgets with InvalidParameterException
  # ("this budget time unit: DAILY only supports notification type as
  # ACTUAL"). Single day's spend doesn't carry enough signal to project
  # period-end credibly — makes sense once you think about it.
  # Skip the FORECASTED block entirely when time_unit == "DAILY".
  dynamic "notification" {
    for_each = var.time_unit == "DAILY" ? [] : var.threshold_percents
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "FORECASTED"
      subscriber_email_addresses = var.notification_emails
      subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
    }
  }

  tags = var.tags
}
