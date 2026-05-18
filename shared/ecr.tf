# ECR — one repo per service. Lives in the Shared account, primary region
# var.region (eu-central-1). Cross-region replication to
# var.replication_destination_region (us-east-1) so workload accounts in
# either region pull from a local copy.
#
# Workload accounts (Staging, Production, Dev) get cross-account pull
# permissions via the repository policy.

resource "aws_ecr_repository" "service" {
  for_each = toset(var.ecr_repos)

  name                 = each.key
  image_tag_mutability = "MUTABLE" # allow re-pushing :latest during dev; CI uses immutable SHAs for prod
  tags                 = merge(var.tags, { "meandr:service" = each.key })

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256" # default; KMS upgrade is a future call if needed
  }
}

# --- Lifecycle policy — keep storage costs bounded -----------------------

resource "aws_ecr_lifecycle_policy" "service" {
  for_each = aws_ecr_repository.service

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 production-tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "release-"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 50 commit-SHA-tagged images (dev cycles)"
        selection = {
          tagStatus   = "tagged"
          tagPatternList = ["sha-*"]
          countType   = "imageCountMoreThan"
          countNumber = 50
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "Drop untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
    ]
  })
}

# --- Cross-account pull policy --------------------------------------------
#
# Workload accounts' ECS task execution roles pull images from here. They
# don't have any other ECR access — only Get/BatchGetImage.

data "aws_iam_policy_document" "ecr_cross_account_pull" {
  statement {
    sid    = "AllowWorkloadAccountsToPull"
    effect = "Allow"

    principals {
      type = "AWS"
      identifiers = [for acct in var.workload_account_ids : "arn:aws:iam::${acct}:root"]
    }

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]
  }
}

resource "aws_ecr_repository_policy" "service" {
  for_each = aws_ecr_repository.service

  repository = each.value.name
  policy     = data.aws_iam_policy_document.ecr_cross_account_pull.json
}

# --- Cross-region replication ---------------------------------------------
#
# ECR replication is account-wide — one config per source region covers all
# the repos in that region. Replicates everything to us-east-1 so the
# us-east-1 workload tasks pull from a local copy.

resource "aws_ecr_replication_configuration" "primary" {
  replication_configuration {
    rule {
      destination {
        region      = var.replication_destination_region
        registry_id = local.shared_account_id
      }
    }
  }
}
