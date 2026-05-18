# GitHub Actions OIDC trust.
#
# One OIDC provider per AWS account. This file sets it up for the Shared
# account. Each workload account (Staging, Production) will have its own
# OIDC provider (in their respective per-account modules).
#
# Infra (Terraform plan/apply) is run from the operator's laptop via SSO —
# no CI trust role here. Only image-pushing roles are needed in Shared,
# since CI's job in Shared is purely "build and push to ECR." Application-
# layer deploys (ecs update-service) get their own roles in workload accounts.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # GitHub's TLS cert chain is validated against AWS's trusted CA list since
  # 2023; thumbprint is no longer strictly required but is still included
  # for older AWS SDKs / regions. These are GitHub Actions' well-known certs.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = var.tags
}

# --- Trust policy subs -----------------------------------------------------

locals {
  # Allowed `sub` claims for image-pushing repos. Permit pushes from any branch
  # plus PR builds (PR builds will skip the actual push step in CI, but they
  # need to authenticate to AWS for the build-and-verify path).
  image_pusher_subs = flatten([
    for repo in var.image_pusher_repos : [
      "repo:${var.github_org}/${repo}:ref:refs/heads/main",
      "repo:${var.github_org}/${repo}:ref:refs/heads/develop",
      "repo:${var.github_org}/${repo}:pull_request",
    ]
  ])
}

# --- Role: ECR push (used by meandr-mcp + meandr-api builds) ---------------

resource "aws_iam_role" "gh_actions_ecr_push" {
  name = "gh-actions-ecr-push"
  tags = var.tags

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
            "token.actions.githubusercontent.com:sub" = local.image_pusher_subs
          }
        }
      }
    ]
  })
}

data "aws_iam_policy_document" "ecr_push" {
  statement {
    sid     = "AuthorizeToECR"
    effect  = "Allow"
    actions = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid    = "PushImagesToOurRepos"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]
    resources = [for r in var.ecr_repos : "arn:aws:ecr:${var.region}:${local.shared_account_id}:repository/${r}"]
  }
}

resource "aws_iam_policy" "ecr_push" {
  name        = "gh-actions-ecr-push"
  description = "Push container images to meandr ECR repos"
  policy      = data.aws_iam_policy_document.ecr_push.json
  tags        = var.tags
}

resource "aws_iam_role_policy_attachment" "ecr_push" {
  role       = aws_iam_role.gh_actions_ecr_push.name
  policy_arn = aws_iam_policy.ecr_push.arn
}
