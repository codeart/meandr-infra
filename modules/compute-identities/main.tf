# The hosted fleet's IAM identities (hosted_nodes.md §6). IAM is
# account-global and every fleet region shares them, so they live in the
# account stack; each region's compute-vpc looks them up by name.

locals {
  base_tags = merge(var.tags, { Component = "hosted-fleet" })

  # compute-vpc's cluster, and the shared account's images a machine runs.
  cluster            = "meandr-hosted"
  image_repositories = ["meandr-agent", "meandr-runner"]
}

data "aws_caller_identity" "current" {}

# Instance role: reachable only by escaping a container, since bridge
# containers cannot reach IMDS (hop limit 1). What it keeps, and why no
# managed policy: hosted_nodes.md §6.
resource "aws_iam_role" "node" {
  name = "hosted-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.base_tags
}

resource "aws_iam_role_policy" "node" {
  name = "hosted-node"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcsAgentDiscovery"
        Effect   = "Allow"
        Action   = "ecs:DiscoverPollEndpoint"
        Resource = "*"
      },
      # No drain, no deregister: spot draining is off, BE terminates.
      {
        Sid    = "EcsAgentInFleetCluster"
        Effect = "Allow"
        Action = [
          "ecs:RegisterContainerInstance",
          "ecs:Poll",
          "ecs:StartTelemetrySession",
          "ecs:SubmitAttachmentStateChanges",
          "ecs:SubmitContainerStateChange",
          "ecs:SubmitTaskStateChange",
        ]
        Resource = [
          "arn:aws:ecs:*:${data.aws_caller_identity.current.account_id}:cluster/${local.cluster}",
          "arn:aws:ecs:*:${data.aws_caller_identity.current.account_id}:container-instance/${local.cluster}/*",
        ]
      },
      {
        Sid      = "EcrToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PullFleetImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [for repo in local.image_repositories : "arn:aws:ecr:*:${var.image_account_id}:repository/${repo}"]
      },
      # Operator Run Command and sessions; never parameter reads.
      {
        Sid    = "SsmAgent"
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssm:ListInstanceAssociations",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
          "ec2messages:AcknowledgeMessage",
          "ec2messages:DeleteMessage",
          "ec2messages:FailMessage",
          "ec2messages:GetEndpoint",
          "ec2messages:GetMessages",
          "ec2messages:SendReply",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "hosted-node"
  role = aws_iam_role.node.name
}

# One SHARED task-execution role: assumed by the ECS agent, never exposed
# to the workload — with no task role assigned, the customer's container
# holds no AWS credentials at all (hosted_nodes.md §6).
resource "aws_iam_role" "task_execution" {
  name = "hosted-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.base_tags
}

# Pulls only: tasks read no secrets or parameters and ship no logs
# (hosted_nodes.md §6, §7.6, §8.2).
resource "aws_iam_role_policy" "task_execution" {
  name = "hosted-task-execution"
  role = aws_iam_role.task_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PullFleetImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [for repo in local.image_repositories : "arn:aws:ecr:*:${var.image_account_id}:repository/${repo}"]
      },
    ]
  })
}

# EventBridge's delivery role for the control-plane event log
# (contracts/hosted_platform_events.md): every region's api destinations.
resource "aws_iam_role" "events_invoke" {
  name = "hosted-events-invoke"
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
      Resource = "arn:aws:events:*:${data.aws_caller_identity.current.account_id}:api-destination/hosted-*"
    }]
  })
}
