# Bootstrap — Terraform state backend in the Shared account.
#
# Chicken-and-egg: this module creates the S3 bucket + DynamoDB table that
# every OTHER module will use as a remote backend. It cannot use that
# backend itself; it uses LOCAL state. The state file lives next to this
# .tf — gitignored and on the operator's laptop only. Loss of that file
# is recoverable via `terraform import` against the live resources.
#
# Run with SSO credentials for AdministratorAccess on the Shared account
# (303529433558). See ../README.md for setup.

provider "aws" {
  region = var.region
}

# --- Sanity check: refuse to apply unless we're in the Shared account.
data "aws_caller_identity" "current" {}

locals {
  shared_account_id = "303529433558"
}

resource "null_resource" "account_guard" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == local.shared_account_id
      error_message = "Bootstrap must run in the Shared account (${local.shared_account_id}). Current account: ${data.aws_caller_identity.current.account_id}."
    }
  }
}

# --- KMS key encrypting state at rest.
resource "aws_kms_key" "tfstate" {
  description             = "Encrypts Terraform state at rest in S3 + DynamoDB"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "tfstate" {
  name          = var.kms_alias
  target_key_id = aws_kms_key.tfstate.key_id
}

# --- Access-log bucket. State bucket logs land here for audit.
resource "aws_s3_bucket" "logs" {
  bucket = var.log_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    expiration {
      days = 365
    }
  }
}

# --- Terraform state bucket.
resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name
  tags   = var.tags

  # Prevent accidental destruction. Removing this requires a deliberate
  # `terraform state rm` first.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_logging" "tfstate" {
  bucket        = aws_s3_bucket.tfstate.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "tfstate/"
}

# --- DynamoDB table for state locks. Single table, all envs share.
# Locks are keyed by the bucket+key combination, so cross-env contention
# is impossible by design.
resource "aws_dynamodb_table" "tfstate_locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.tfstate.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = var.tags
}
