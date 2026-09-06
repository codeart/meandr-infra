# ML spike detection, complementing aws-budget: Budgets alert once daily
# after a fixed threshold, so a 10x morning cannot surface until the daily
# total crosses it. Free service.

# DIMENSIONAL names the service that spiked; a total-only monitor does not.
resource "aws_ce_anomaly_monitor" "main" {
  name              = "${var.name}-account-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"

  tags = var.tags
}

resource "aws_ce_anomaly_subscription" "main" {
  name      = "${var.name}-subscription"
  frequency = "IMMEDIATE"

  monitor_arn_list = [aws_ce_anomaly_monitor.main.arn]

  subscriber {
    type    = "SNS"
    address = var.sns_topic_arn
  }

  # Dollars OVER the per-service baseline, not total spend.
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = [tostring(var.threshold_usd)]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }

  tags = var.tags
}

# A second subscription, because AWS pairs frequency with subscriber type:
# IMMEDIATE takes SNS, DAILY and WEEKLY take EMAIL. The one above is the
# machine-readable alert; this is the one a human reads — AWS renders it
# as a table, where the SNS payload arrives as raw JSON.
#
# Same monitor and same threshold, so the two can never disagree about
# what counts as an anomaly.
resource "aws_ce_anomaly_subscription" "email" {
  count = length(var.alert_emails) > 0 ? 1 : 0

  name      = "${var.name}-subscription-email"
  frequency = var.email_frequency

  monitor_arn_list = [aws_ce_anomaly_monitor.main.arn]

  dynamic "subscriber" {
    for_each = var.alert_emails
    content {
      type    = "EMAIL"
      address = subscriber.value
    }
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = [tostring(var.threshold_usd)]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }

  tags = var.tags
}

# The CALLER must grant costalerts.amazonaws.com Publish on the topic.
# aws-budget's policy covers budgets.amazonaws.com only, and alerts are
# dropped silently without it. Left to the caller so two modules do not
# fight over one topic policy.
