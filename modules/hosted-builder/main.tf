# One region's tenant image builder (hosted_nodes.md §7.7, contract in
# contracts/hosted_image_build.md): BuildKit on CodeBuild, one project per
# architecture, base images through ECR's pull-through cache.

locals {
  base_tags = merge(var.tags, { Component = "hosted-builder" })
  registry  = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"

  architectures = {
    arm64 = { type = "ARM_CONTAINER", image = "aws/codebuild/amazonlinux-aarch64-standard:4.0" }
    amd64 = { type = "LINUX_CONTAINER", image = "aws/codebuild/amazonlinux-x86_64-standard:6.0" }
  }

  # Cache prefix => upstream; compute-identities grants the same prefixes.
  upstreams = {
    "docker-hub" = { url = "registry-1.docker.io", registry = "docker.io" }
    "ghcr"       = { url = "ghcr.io", registry = "ghcr.io" }
  }

  # Mirrors with the cache's path prefix, so FROM lines work unchanged.
  buildkitd_toml = join("\n", [
    for prefix, u in local.upstreams : "[registry.\"${u.registry}\"]\n  mirrors = [\"${local.registry}/${prefix}\"]"
  ])
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Account-global, from modules/compute-identities.
data "aws_iam_role" "builder" {
  name = "hosted-builder"
}

resource "aws_cloudwatch_log_group" "builds" {
  name              = "/aws/codebuild/hosted-builder"
  retention_in_days = var.log_retention_days
  tags              = local.base_tags
}

resource "aws_codebuild_project" "builder" {
  for_each = local.architectures

  name           = "hosted-builder-${each.key}"
  description    = "Builds tenant images for ${each.key} hosted nodes."
  service_role   = data.aws_iam_role.builder.arn
  build_timeout  = 60
  queued_timeout = 60
  tags           = local.base_tags

  source {
    type = "NO_SOURCE"
    buildspec = templatefile("${path.module}/buildspec.yml", {
      registry         = local.registry
      buildkit_version = var.buildkit_version
    })
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  # Never a local cache: a later build could put one tenant's layers in another's image.
  cache {
    type = "NO_CACHE"
  }

  environment {
    type                        = each.value.type
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = each.value.image
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name  = "ARCH"
      value = each.key
    }

    environment_variable {
      name  = "BUILDKITD_TOML"
      value = local.buildkitd_toml
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.builds.name
      stream_name = each.key
    }
  }
}

# --- Pull-through cache --------------------------------------------------

# Values are put by hand in the home region, never through Terraform:
# {"username": "...", "accessToken": "..."}.
resource "aws_secretsmanager_secret" "upstream" {
  for_each = var.secrets_home ? local.upstreams : {}

  name        = "ecr-pullthroughcache/${each.key}"
  description = "Read-only ${each.value.registry} credentials for ECR's pull-through cache."
  tags        = local.base_tags

  dynamic "replica" {
    for_each = var.replica_regions
    content {
      region = replica.value
    }
  }

  # Tokens are reissued at the source, never recovered; a pending deletion
  # would hold the name, and its replicas', for 30 days.
  recovery_window_in_days = 0
}

data "aws_secretsmanager_secret" "upstream" {
  for_each = !var.secrets_home && var.upstream_credentials ? local.upstreams : {}

  name = "ecr-pullthroughcache/${each.key}"
}

resource "aws_ecr_pull_through_cache_rule" "upstream" {
  for_each = var.upstream_credentials ? local.upstreams : {}

  ecr_repository_prefix = each.key
  upstream_registry_url = each.value.url
  credential_arn        = var.secrets_home ? aws_secretsmanager_secret.upstream[each.key].arn : data.aws_secretsmanager_secret.upstream[each.key].arn
}

# A cached image past 30 days is dropped and fetched again on its next pull.
resource "aws_ecr_repository_creation_template" "cache" {
  for_each = local.upstreams

  prefix               = each.key
  description          = "Base images cached for tenant builds."
  applied_for          = ["PULL_THROUGH_CACHE"]
  image_tag_mutability = "MUTABLE"

  lifecycle_policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire cached images after 30 days."
      selection = {
        tagStatus   = "any"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}
