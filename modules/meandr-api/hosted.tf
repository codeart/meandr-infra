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

  # BE's agent client key (hosted_agent_homes.md §8): the private key for
  # jobs alone, the public keys for the reports puma answers.
  agent_client_key_env         = var.agent_client_key_secret_arn == "" ? {} : { MEANDR_AGENT_CLIENT_KEY = var.agent_client_key_secret_arn }
  agent_client_public_keys_env = var.agent_client_public_keys == "" ? {} : { MEANDR_AGENT_CLIENT_PUBLIC_KEYS = var.agent_client_public_keys }
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
        Resource = distinct([for f in var.hosted_fleets : f.node_role_arn])
        Condition = {
          StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" }
        }
      },
      {
        Sid      = "TaskDefinitionNamesTheExecutionRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = distinct([for f in var.hosted_fleets : f.task_execution_role_arn])
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
      # Tenant images (contracts/hosted_image_build.md): repositories, the
      # sweep, and a built image's config for the entryPoint composition.
      {
        Sid    = "TenantRepositories"
        Effect = "Allow"
        Action = [
          "ecr:CreateRepository",
          "ecr:DeleteRepository",
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "ecr:BatchDeleteImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [for r in local.hosted_regions : "arn:aws:ecr:${r}:${var.account_id}:repository/hosted/*"]
      },
      # Meandr's app images (product/apps.md §2, §3): their versions and the
      # manifest label, in the shared account's apps/* repositories.
      {
        Sid      = "AppImages"
        Effect   = "Allow"
        Action   = ["ecr:DescribeImages", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = [for r in local.hosted_regions : "arn:aws:ecr:${r}:${split(".", var.ecr_registry)[0]}:repository/apps/*"]
      },
      {
        Sid      = "ImageBuilds"
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild", "codebuild:StopBuild", "codebuild:BatchGetBuilds"]
        Resource = [for r in local.hosted_regions : "arn:aws:codebuild:${r}:${var.account_id}:project/hosted-builder-*"]
      },
      {
        Sid      = "BuildOutput"
        Effect   = "Allow"
        Action   = "logs:GetLogEvents"
        Resource = [for r in local.hosted_regions : "arn:aws:logs:${r}:${var.account_id}:log-group:/aws/codebuild/hosted-builder:*"]
      },
    ]
  })
}

# Puma validates the events bearer on /api/hosted/v1/events at request time.
# That secret alone: BE's agent client key sits beside it under
# meandr/hosted/<env>/, and it stays out of the internet-facing process.
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
      Resource = "arn:aws:secretsmanager:${local.region}:${var.account_id}:secret:meandr/hosted/${var.env}/events-token-*"
    }]
  })
}
