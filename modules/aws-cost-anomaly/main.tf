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

# The CALLER must grant costalerts.amazonaws.com Publish on the topic.
# aws-budget's policy covers budgets.amazonaws.com only, and alerts are
# dropped silently without it. Left to the caller so two modules do not
# fight over one topic policy.
