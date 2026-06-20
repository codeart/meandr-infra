# AWS Cost Anomaly Detection — ML-driven spike detection.
#
# AWS Budgets has a DAILY floor: alerts fire once daily at most, and
# only after spend crosses a fixed threshold. That misses the "9am to
# noon costs went 10× normal" case until the daily total finally
# crosses 95% of $X.
#
# Cost Anomaly Detection is the complementary tool: ML baseline of
# normal daily spend per service, flags actual that exceeds baseline
# by `threshold_usd`, sends to SNS within minutes. Free service —
# AWS doesn't charge for the monitor or the alerts.
#
# Frequency: IMMEDIATE (the SNS topic forwards to email; we want the
# alert in the operator's inbox as fast as possible). DAILY frequency
# is also available — that batches anomalies into a daily summary
# email, less useful for the "runaway-cost" case this module exists
# to catch.

# Monitor scoped to the whole account by service dimension. The
# DIMENSIONAL monitor type alerts when any single AWS service's spend
# deviates from baseline — so the alert tells you "EC2 spiked" vs
# "RDS spiked," not just "the account total spiked." More useful.
resource "aws_ce_anomaly_monitor" "main" {
  name              = "${var.name}-account-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"

  tags = var.tags
}

# Subscription routes alerts above threshold to the SNS topic.
# Threshold is the absolute USD-over-baseline deviation; AWS computes
# the baseline per service per day from the trailing 10-90 days of
# spend, so the threshold is "how much above normal counts as
# anomalous" rather than "how much spend is too much."
resource "aws_ce_anomaly_subscription" "main" {
  name      = "${var.name}-subscription"
  frequency = "IMMEDIATE"

  monitor_arn_list = [aws_ce_anomaly_monitor.main.arn]

  subscriber {
    type    = "SNS"
    address = var.sns_topic_arn
  }

  # ThresholdExpression replaced the deprecated `threshold` attribute.
  # ANOMALY_TOTAL_IMPACT_ABSOLUTE = dollars-over-baseline.
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = [tostring(var.threshold_usd)]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }

  tags = var.tags
}

# Note on SNS topic policy: the budget module (aws-budget) creates the
# topic with a policy allowing `budgets.amazonaws.com` to Publish.
# Cost Anomaly Detection publishes as `costalerts.amazonaws.com`,
# which the existing policy does NOT cover. The caller of this module
# needs to extend the topic policy to include costalerts.amazonaws.com
# — see modules/aws-budget for the policy shape, or use the
# aws_sns_topic_policy resource directly in the caller to add both
# principals. (Keeping the policy management in the caller rather
# than this module avoids two modules fighting over the same topic
# resource.)
