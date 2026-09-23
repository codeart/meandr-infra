# The hosted fleet's IAM identities (hosted_nodes.md §6). IAM is
# account-global and every fleet region shares them, so they live in the
# account stack; each region's compute-vpc looks them up by name.

locals {
  base_tags = merge(var.tags, { Component = "hosted-fleet" })
}

data "aws_caller_identity" "current" {}

# Instance role: ECS agent registration + SSM (log snapshots ride
# RunCommand). Nothing more — a bridge container cannot reach IMDS
# (hop limit 1), and the role stays minimal anyway.
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

resource "aws_iam_role_policy_attachment" "node_ecs" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
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

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Any region: every fleet region's tasks run as this role. The agent token
# is the primary's secret and its replicas, which share its name.
resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "read-hosted-secrets"
  role = aws_iam_role.task_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "HostedNodeParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameters"]
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/meandr/hosted/*"
      },
      {
        Sid      = "AgentToken"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:meandr/hosted/${var.env}/agent-token-??????"
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
