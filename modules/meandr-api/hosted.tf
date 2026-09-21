# Hosted-fleet orchestration (hosted_nodes.md §5, §7.5): BE buys nodes,
# registers task defs, and runs one ECS service per ServerNode. Every
# mutating grant is fenced to the fleet — tag-scoped terminate, cluster-
# conditioned ECS — so a compromised BE cannot touch the main VPC's boxes.
#
# JOBS ROLE ONLY: launch/retire runs in Hosted::* jobs. Puma gets just
# the token reads (below) — the internet-facing process can't buy or
# kill anything.

locals {
  hosted_regions      = [for f in var.hosted_fleets : f.region]
  hosted_cluster_arns = [for f in var.hosted_fleets : f.cluster_arn]
}

resource "aws_iam_role_policy" "jobs_hosted" {
  count = length(var.hosted_fleets) == 0 ? 0 : 1

  name = "hosted-orchestration"
  role = aws_iam_role.task_acme.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SeeMachines"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeSubnets",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeLaunchTemplateVersions",
        ]
        Resource = "*"
      },
      {
        Sid    = "BuyMachines"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = local.hosted_regions }
        }
      },
      # Launch-time only: tags cannot be added or changed on running
      # instances, so nothing can be re-tagged into (or out of) the
      # terminate scope below.
      {
        Sid      = "TagAtLaunch"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "*"
        Condition = {
          StringEquals = { "ec2:CreateAction" = ["RunInstances", "CreateFleet"] }
        }
      },
      # Only instances BE stamped at launch — never NAT, Valkey, or a
      # proxy host. An untagged launch is unkillable by BE: tag or leak.
      {
        Sid      = "RetireMachines"
        Effect   = "Allow"
        Action   = "ec2:TerminateInstances"
        Resource = "*"
        Condition = {
          StringEquals = { "aws:ResourceTag/meandr:role" = "hosted-node" }
        }
      },
      {
        Sid      = "LaunchTemplateCarriesTheInstanceProfile"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [for f in var.hosted_fleets : f.node_role_arn]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" }
        }
      },
      {
        Sid      = "TaskDefinitionNamesTheExecutionRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [for f in var.hosted_fleets : f.task_execution_role_arn]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      # RegisterTaskDefinition takes no resource scoping (AWS limitation);
      # the defs are inert until a service in the fleet cluster names them.
      {
        Sid    = "TaskDefinitions"
        Effect = "Allow"
        Action = [
          "ecs:RegisterTaskDefinition",
          "ecs:DeregisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
          "ecs:TagResource",
        ]
        Resource = "*"
      },
      # Everything cluster-scoped is fenced to the fleet clusters — the
      # main cluster running BE itself stays out of reach. Two statements
      # because the fence differs: actions on things INSIDE a cluster
      # carry the ecs:cluster key; actions ON the cluster itself don't —
      # there the cluster ARN is the resource.
      {
        Sid    = "FleetClusterMembers"
        Effect = "Allow"
        Action = [
          "ecs:CreateService",
          "ecs:UpdateService",
          "ecs:DeleteService",
          "ecs:DescribeServices",
          "ecs:ListTasks",
          "ecs:DescribeTasks",
          "ecs:DescribeContainerInstances",
          "ecs:PutAttributes",
        ]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = local.hosted_cluster_arns }
        }
      },
      {
        Sid    = "FleetCluster"
        Effect = "Allow"
        Action = [
          "ecs:ListContainerInstances",
          "ecs:PutAttributes",
        ]
        Resource = local.hosted_cluster_arns
      },
      {
        Sid    = "NodeParameters"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:DeleteParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = [for r in local.hosted_regions : "arn:aws:ssm:${r}:${var.account_id}:parameter/meandr/hosted/*"]
      },
    ]
  })
}

# Puma validates the agent/events bearers on /api/hosted/v1/* at request
# time; both env tokens live in the API region only.
resource "aws_iam_role_policy" "task_hosted_tokens" {
  count = length(var.hosted_fleets) == 0 ? 0 : 1

  name = "hosted-tokens"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "HostedTokens"
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = "arn:aws:secretsmanager:${local.region}:${var.account_id}:secret:meandr/hosted/${var.env}/*"
    }]
  })
}
