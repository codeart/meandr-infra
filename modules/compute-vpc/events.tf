# EventBridge → BE: the control-plane event log for hosted nodes
# (contracts/hosted_platform_events.md). Reconciliation must not depend
# on a write we might have dropped, so AWS itself narrates the fleet.

data "aws_cloudwatch_event_bus" "default" {
  name = "default"
}

locals {
  event_routes = {
    ec2_instance_states     = "/api/hosted/v1/events/ec2_instance_states"
    ecs_container_instances = "/api/hosted/v1/events/ecs_container_instances"
    ecs_tasks               = "/api/hosted/v1/events/ecs_tasks"
  }
}

# AWS and the instance agents are different trust domains: a compromised
# node must not be able to forge task-state events, so deliveries bear
# their own env-wide token, never the agent one.
resource "aws_cloudwatch_event_connection" "events" {
  name               = "hosted-events"
  authorization_type = "API_KEY"

  auth_parameters {
    api_key {
      key   = "Authorization"
      value = "Bearer ${var.events_token}"
    }
  }
}

# 10/s per destination: a burst (a reaper terminating twenty machines)
# queues inside EventBridge and drains gently instead of spiking BE.
resource "aws_cloudwatch_event_api_destination" "events" {
  for_each = local.event_routes

  name                             = "hosted-${replace(each.key, "_", "-")}"
  connection_arn                   = aws_cloudwatch_event_connection.events.arn
  invocation_endpoint              = "${var.api_base_url}${each.value}"
  http_method                      = "POST"
  invocation_rate_limit_per_second = 10
}

# EC2 events carry only instance-id + state — nothing to filter on, so
# every instance in the account+region fires this (NAT, Valkey, …). BE
# treats unknown ids as noise.
resource "aws_cloudwatch_event_rule" "ec2_instance_states" {
  name = "hosted-ec2-instance-states"
  tags = local.base_tags

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
}

resource "aws_cloudwatch_event_rule" "ecs_container_instances" {
  name = "hosted-ecs-container-instances"
  tags = local.base_tags

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Container Instance State Change"]
    detail      = { clusterArn = [aws_ecs_cluster.hosted.arn] }
  })
}

resource "aws_cloudwatch_event_rule" "ecs_tasks" {
  name = "hosted-ecs-tasks"
  tags = local.base_tags

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail      = { clusterArn = [aws_ecs_cluster.hosted.arn] }
  })
}

# A message here means an event BE permanently refused — the alarm is
# the pager, the queue holds the evidence for 14 days.
resource "aws_sqs_queue" "events_dlq" {
  name                      = "hosted-events-dlq"
  message_retention_seconds = 1209600
  tags                      = local.base_tags
}

resource "aws_sqs_queue_policy" "events_dlq" {
  queue_url = aws_sqs_queue.events_dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.events_dlq.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = [
            aws_cloudwatch_event_rule.ec2_instance_states.arn,
            aws_cloudwatch_event_rule.ecs_container_instances.arn,
            aws_cloudwatch_event_rule.ecs_tasks.arn,
          ]
        }
      }
    }]
  })
}

# Region-qualified: IAM names are account-global and production runs two
# fleet regions in one account.
resource "aws_iam_role" "events_invoke" {
  name = "hosted-events-invoke-${var.region_code}"
  tags = local.base_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "events_invoke" {
  name = "invoke"
  role = aws_iam_role.events_invoke.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:InvokeApiDestination"
      Resource = [for d in aws_cloudwatch_event_api_destination.events : d.arn]
    }]
  })
}

resource "aws_cloudwatch_event_target" "events" {
  for_each = {
    ec2_instance_states     = aws_cloudwatch_event_rule.ec2_instance_states.name
    ecs_container_instances = aws_cloudwatch_event_rule.ecs_container_instances.name
    ecs_tasks               = aws_cloudwatch_event_rule.ecs_tasks.name
  }

  rule     = each.value
  arn      = aws_cloudwatch_event_api_destination.events[each.key].arn
  role_arn = aws_iam_role.events_invoke.arn

  retry_policy {
    maximum_event_age_in_seconds = 86400
    maximum_retry_attempts       = 185
  }

  dead_letter_config {
    arn = aws_sqs_queue.events_dlq.arn
  }
}

resource "aws_cloudwatch_metric_alarm" "events_dlq" {
  alarm_name  = "hosted-events-dlq"
  namespace   = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  dimensions  = { QueueName = aws_sqs_queue.events_dlq.name }

  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_topic_arns
  ok_actions    = var.alarm_topic_arns
  tags          = local.base_tags
}

# Replay source of last resort: 14 days of raw aws.ec2/aws.ecs, cheap.
resource "aws_cloudwatch_event_archive" "events" {
  name             = "hosted-events"
  event_source_arn = data.aws_cloudwatch_event_bus.default.arn
  retention_days   = 14
  event_pattern    = jsonencode({ source = ["aws.ec2", "aws.ecs"] })
}
