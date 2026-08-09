# S3 bucket for captured payloads and the Parquet archive.
#
# One module, two uses (capture_and_archive.md §6):
#
#   meandr-mcp-archive-<env>              calls + actions Parquet, ONE per env,
#                                         written by BE, queried by Athena
#   meandr-mcp-payloads-<region>-<env>    request/response bodies, one per
#                                         REGION, written by the proxy, read
#                                         only by ranged GET
#
# The split is what keeps Athena single-region: bodies must be regional
# (the proxy writes them on the hot path), but nothing ever scans them —
# a ref names the bucket and the byte range. Only the metadata is queried,
# and BE writes that centrally from Postgres.

resource "aws_s3_bucket" "this" {
  bucket = var.name
  tags   = var.tags
}

# ACLs off entirely. Every access decision is an IAM/bucket policy, which
# is the only model worth reasoning about.
resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning stays OFF, deliberately.
#
# Segments are write-once — we never rewrite one — so versioning protects
# against a mistake this design structurally cannot make. What it WOULD do
# is break the retention promise: with versioning on, a lifecycle
# expiration writes a delete marker and keeps the object as a noncurrent
# version, so data we have told a customer is deleted keeps billing until
# two further rules clean it up.
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Disabled"
  }
}

# SSE-KMS with the per-env payload CMK (capture_and_archive.md §10).
#
# bucket_key_enabled is not optional at this volume: without it S3 calls
# KMS once per object operation ($0.03/10k). A bucket key derives a
# short-lived data key and cuts those calls by up to 99%.
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  # NON-NEGOTIABLE (capture_and_archive.md §7.2). An abandoned multipart
  # upload leaves parts that are invisible in listings and billed
  # forever, and this design EXPECTS abandonment: drain timeouts,
  # SIGKILL, a regional incident. Without this rule the bill grows from
  # objects nobody can see.
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_days
    }
  }

  # One rule per retention class. Expiration.Days counts from each
  # object's own creation date, so a single rule gives every object its
  # own clock — there is no per-object expiry attribute in S3, and none
  # is needed.
  #
  # Rules must NOT overlap. If an object matched two, which expiry wins
  # is a question about S3's precedence that a retention promise should
  # not rest on — so there is no catch-all rule.
  #
  # An UNTAGGED object therefore matches nothing and lives forever, and
  # that cannot be prevented at the bucket. A policy denying PUTs without
  # the tag also denies UploadPart: CreateMultipartUpload, UploadPart and
  # CompleteMultipartUpload all authorize as s3:PutObject, only the first
  # carries x-amz-tagging, and no condition key separates them. An
  # "allow-only" variant does not help either — for a same-account
  # principal S3 grants on IAM *or* bucket policy, so Allow statements
  # cannot take away what the task role already has. Only Deny restricts,
  # and Deny is what breaks the parts.
  #
  # So the guard is operational, decided 2026-08-03: the writer sets the
  # tag at its single call site (unit-tested), and a monthly sweep lists
  # objects, finds any that carry no retention tag, and deletes them.
  # If the sweep never finds anything, the test is doing its job.
  dynamic "rule" {
    for_each = var.retention_classes

    content {
      id     = "retention-${rule.key}"
      status = "Enabled"

      filter {
        tag {
          key   = "retention"
          value = rule.key
        }
      }

      expiration {
        days = rule.value
      }
    }
  }

  # Prefix-scoped expiry for machinery droppings — objects a SERVICE
  # writes into the bucket (Athena query results above all), untagged
  # and otherwise immortal. No overlap with the tag rules: these
  # prefixes hold no retention-tagged objects.
  dynamic "rule" {
    for_each = var.prefix_expirations

    content {
      id     = "prefix-expire-${trimsuffix(rule.key, "/")}"
      status = "Enabled"

      filter {
        prefix = rule.key
      }

      expiration {
        days = rule.value
      }
    }
  }
}

# TLS-only. S3 accepts plain HTTP otherwise, and a bucket holding
# customer payloads should not.
resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.this.json
}

data "aws_iam_policy_document" "this" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

}
