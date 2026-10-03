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
  tags = merge(var.tags, {
    "meandr:service" = each.key
    Name             = local.ecr_display_names[each.key]
  })

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256" # default; KMS upgrade is a future call if needed
  }
}

# --- Lifecycle policy — keep storage costs bounded -----------------------

# Keep what runs plus the 5 newest builds; delete everything else. An image
# matched by a rule cannot be expired by a LOWER-priority one, which is what
# lets rules 1-2 shield main and develop from rule 4. var.ecr_keep_all_builds
# repos skip rule 4: a hosted node may run any build it ever deployed.
locals {
  ecr_lifecycle_rules = {
    base = [
      {
        rulePriority = 1
        description  = "Keep what production runs"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["main"]
          countType      = "imageCountMoreThan"
          countNumber    = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep what staging runs"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["develop"]
          countType      = "imageCountMoreThan"
          countNumber    = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "Drop untagged images after a day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
    ]
    recent = [
      {
        rulePriority = 4
        description  = "Keep only the 5 newest other builds"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 5
        }
        action = { type = "expire" }
      },
    ]
  }

  ecr_lifecycle_policy = {
    for repo in var.ecr_repos : repo => jsonencode({
      rules = concat(local.ecr_lifecycle_rules.base,
      contains(var.ecr_keep_all_builds, repo) ? [] : local.ecr_lifecycle_rules.recent)
    })
  }
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each = aws_ecr_repository.service

  repository = each.value.name
  policy     = local.ecr_lifecycle_policy[each.key]
}

# --- Cross-account pull policy --------------------------------------------
#
# Each repo is pulled only by the roles var.ecr_pullers names for it, so a
# hosted machine's instance role reaches the hosted images and never ours.

data "aws_iam_policy_document" "ecr_cross_account_pull" {
  for_each = toset(var.ecr_repos)

  statement {
    sid    = "AllowNamedWorkloadRolesToPull"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [for acct in var.workload_account_ids : "arn:aws:iam::${acct}:root"]
    }

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values = flatten([
        for acct in var.workload_account_ids : [
          for role in var.ecr_pullers[each.key] : "arn:aws:iam::${acct}:role/${role}"
        ]
      ])
    }
  }
}

resource "aws_ecr_repository_policy" "service" {
  for_each = aws_ecr_repository.service

  repository = each.value.name
  policy     = data.aws_iam_policy_document.ecr_cross_account_pull[each.key].json
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

# Replication copies IMAGES ONLY — the replica repositories arrive with no
# repository policy (so workload accounts get 403 on pull) and no lifecycle
# policy (so they never expire anything).
#
# Keyed by name, not by resource: replication creates the repositories, so
# Terraform does not own them. A repo added to var.ecr_repos therefore needs
# one image replicated before these can attach.

resource "aws_ecr_repository_policy" "replica" {
  provider = aws.replica
  for_each = toset(var.ecr_repos)

  repository = each.key
  policy     = data.aws_iam_policy_document.ecr_cross_account_pull[each.key].json
}

resource "aws_ecr_lifecycle_policy" "replica" {
  provider = aws.replica
  for_each = toset(var.ecr_repos)

  repository = each.key
  policy     = local.ecr_lifecycle_policy[each.key]
}
