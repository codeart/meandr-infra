# Fills the mirror and the model bucket (files/mirror.yml): the primary's builds
# TEI for the T4G, an edge's copies the primary's, so every region runs the same
# bytes. Once per TEI version: aws codebuild start-build --project-name meandr-embed-mirror.

locals {
  mirror_env = merge(
    {
      MIRROR      = aws_ecr_repository.tei.repository_url
      TEI_VERSION = var.models.tei_version
      TEI_RELEASE = coalesce(var.models.tei_release, "none")
      BUCKET      = aws_s3_bucket.models.id
      MODELS      = join(" ", compact([var.models.model, var.models.reranker]))
    },
    var.mirror_source == null ? {} : {
      SOURCE_REGION = var.mirror_source.region
      SOURCE_MIRROR = "${local.account}.dkr.ecr.${var.mirror_source.region}.amazonaws.com/${aws_ecr_repository.tei.name}"
      SOURCE_BUCKET = "meandr-models-${var.mirror_source.region}-${var.env}"
    },
  )
}

resource "aws_cloudwatch_log_group" "mirror" {
  name              = "/aws/codebuild/meandr-embed-mirror"
  retention_in_days = 30

  tags = merge(local.tags, { Name = "meandr-embed-mirror" })
}

resource "aws_iam_role" "mirror" {
  name = "meandr-embed-mirror-${var.env}-${local.region}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "meandr-embed-mirror" })
}

resource "aws_iam_role_policy" "mirror" {
  name = "fill-mirror"
  role = aws_iam_role.mirror.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload", "ecr:DescribeImages",
        "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart"]
        Resource = aws_ecr_repository.tei.arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.models.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.models.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.mirror.arn}:*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "mirror_source" {
  count = var.mirror_source == null ? 0 : 1

  name = "read-source"
  role = aws_iam_role.mirror.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = "arn:aws:ecr:${var.mirror_source.region}:${local.account}:repository/${aws_ecr_repository.tei.name}"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${local.mirror_env.SOURCE_BUCKET}"
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::${local.mirror_env.SOURCE_BUCKET}/*"
      },
    ]
  })
}

resource "aws_codebuild_project" "mirror" {
  name           = "meandr-embed-mirror"
  description    = "Fills the TEI mirror and the model bucket"
  service_role   = aws_iam_role.mirror.arn
  build_timeout  = 240
  queued_timeout = 60

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/files/mirror.yml")
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  # Compiling TEI's CUDA kernels wants the memory.
  environment {
    type                        = "ARM_CONTAINER"
    compute_type                = "BUILD_GENERAL1_LARGE"
    image                       = "aws/codebuild/amazonlinux-aarch64-standard:4.0"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    dynamic "environment_variable" {
      for_each = local.mirror_env
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.mirror.name
    }
  }

  tags = merge(local.tags, { Name = "meandr-embed-mirror" })

  # So the job's first apply, targeted at it alone, brings its grants.
  depends_on = [aws_iam_role_policy.mirror, aws_iam_role_policy.mirror_source]
}
