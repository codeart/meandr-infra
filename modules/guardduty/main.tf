# One region's abuse detection (hosted_nodes.md §6): GuardDuty on its
# foundational sources, findings mailed from this region's own topic, since
# an EventBridge rule can only target a topic in its region.

resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  tags                         = var.tags
}

# Billed per event or GB scanned, and none of them watches egress.
resource "aws_guardduty_detector_feature" "off" {
  for_each = toset(["S3_DATA_EVENTS", "EBS_MALWARE_PROTECTION", "RUNTIME_MONITORING"])

  detector_id = aws_guardduty_detector.this.id
  name        = each.key
  status      = "DISABLED"
}

resource "aws_sns_topic" "security" {
  name = "meandr-${var.env}-security"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "security" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.security.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_policy" "security" {
  arn = aws_sns_topic.security.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EventBridgePublishes"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.security.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.findings.arn } }
    }]
  })
}

resource "aws_cloudwatch_event_rule" "findings" {
  name        = "guardduty-findings"
  description = "GuardDuty findings of severity ${var.min_severity} and up."
  tags        = var.tags

  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail        = { severity = [{ numeric = [">=", var.min_severity] }] }
  })
}

# The instance id names the machine, and through it the tenant.
resource "aws_cloudwatch_event_target" "findings" {
  rule = aws_cloudwatch_event_rule.findings.name
  arn  = aws_sns_topic.security.arn

  input_transformer {
    input_paths = {
      severity = "$.detail.severity"
      type     = "$.detail.type"
      title    = "$.detail.title"
      region   = "$.region"
      instance = "$.detail.resource.instanceDetails.instanceId"
      finding  = "$.detail.id"
    }
    input_template = "\"GuardDuty ${var.env} <region>, severity <severity>: <type>. <title> Instance: <instance>. Finding: <finding>\""
  }
}
