resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = merge(var.tags, {
    Name = "GitHub Actions OIDC"
  })
}

# --- Trust policy subs ----------------------------------------------------

locals {
  # Ref-based trust (branch / tag patterns).
  ref_subs = flatten([
    for repo in var.github_repos : [
      for ref in var.allowed_refs : "repo:${var.github_org}/${repo}:ref:${ref}"
    ]
  ])

  # Environment-based trust (GH Actions Environments — used for prod approval gates).
  env_subs = flatten([
    for repo in var.github_repos : [
      for env_name in var.allowed_gh_environments : "repo:${var.github_org}/${repo}:environment:${env_name}"
    ]
  ])

  all_subs = concat(local.ref_subs, local.env_subs)
}

# --- Role: ECS deploy -----------------------------------------------------

resource "aws_iam_role" "gh_actions_deploy" {
  name = "gh-actions-deploy"
  tags = merge(var.tags, {
    Name = "GitHub Actions Deploy"
  })

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = local.all_subs
          }
        }
      }
    ]
  })
}

data "aws_iam_policy_document" "ecs_deploy" {
  # Register new task definitions (the image-update flow).
  statement {
    sid    = "RegisterTaskDefinitions"
    effect = "Allow"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:DeregisterTaskDefinition",
      "ecs:ListTaskDefinitions",
      "ecs:ListTaskDefinitionFamilies",
    ]
    # Task definitions are referenced by family + revision; not scoped to ARN patterns.
    resources = ["*"]
  }

  # Update services to use new task defs. Scoped to meandr-prefixed clusters
  # and services to avoid touching anything else if other workloads land here.
  statement {
    sid    = "UpdateServices"
    effect = "Allow"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:ListServices",
    ]
    resources = [
      "arn:aws:ecs:*:${var.account_id}:service/${var.ecs_cluster_name_prefix}*/${var.ecs_cluster_name_prefix}*",
      "arn:aws:ecs:*:${var.account_id}:task/${var.ecs_cluster_name_prefix}*/*",
      "arn:aws:ecs:*:${var.account_id}:cluster/${var.ecs_cluster_name_prefix}*",
    ]
  }

  # Run one-off tasks (migrations, seeds). Scoped to meandr-prefixed
  # task-definition families AND meandr-prefixed clusters via the
  # ecs:cluster condition key — prevents the role from launching one-off
  # tasks in any other cluster that lands in this account.
  statement {
    sid    = "RunOneOffTasks"
    effect = "Allow"
    actions = [
      "ecs:RunTask",
      "ecs:StopTask",
    ]
    resources = [
      "arn:aws:ecs:*:${var.account_id}:task-definition/${var.ecs_cluster_name_prefix}*:*",
    ]
    condition {
      test     = "ArnLike"
      variable = "ecs:cluster"
      values = [
        "arn:aws:ecs:*:${var.account_id}:cluster/${var.ecs_cluster_name_prefix}*",
      ]
    }
  }

  # iam:PassRole — required for task-definition registration. Scoped to
  # meandr-prefixed roles (task execution role + task role), so this role
  # can't be used to escalate by passing arbitrary roles.
  statement {
    sid     = "PassECSRoles"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${var.account_id}:role/${var.task_role_name_prefix}*",
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # Read ECR (pull existing image manifests for task-def registration).
  statement {
    sid     = "ECRAccess"
    effect  = "Allow"
    actions = ["ecr:GetAuthorizationToken", "ecr:DescribeImages", "ecr:BatchGetImage"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ecs_deploy" {
  name        = "gh-actions-deploy"
  description = "ECS service deploys from GitHub Actions (image promotion + rollout)"
  policy      = data.aws_iam_policy_document.ecs_deploy.json
  tags = merge(var.tags, {
    Name = "GitHub Actions Deploy Policy"
  })
}

resource "aws_iam_role_policy_attachment" "ecs_deploy" {
  role       = aws_iam_role.gh_actions_deploy.name
  policy_arn = aws_iam_policy.ecs_deploy.arn
}
