# development / eu-central-1 — region-level dev workload (cred-store).
#
# Mirror of staging/eu-central-1 in shape, much thinner in scope. The
# dev account today doesn't run any ECS / VPC workload — engineers
# point BE + proxy at localhost Redis from their laptops — so this
# caller only provisions the bits that have to live in AWS:
#
#   - meandr-creds-development DynamoDB table (cred blob storage)
#   - alias/meandr-cred-development KMS CMK (envelope encryption)
#   - IAM policy attached to the existing `meandr-dev` user that
#     grants R/W on the new resources (matches the union of BE-side
#     and proxy-side scopes since one human runs both locally)
#
# The dev IAM user itself + its base SM policy on `meandr/tenants/*`
# stays in account-development/, since identity is account-global.

provider "aws" {
  region  = "eu-central-1"
  profile = "meandr-development"
}

locals {
  account_id = "238020582774" # Development

  tags = {
    "meandr:env"        = "development"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

# --- Account guard ------------------------------------------------------

data "aws_caller_identity" "current" {}

resource "null_resource" "account_guard" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == local.account_id
      error_message = "Account mismatch: expected ${local.account_id}, got ${data.aws_caller_identity.current.account_id}. Wrong AWS_PROFILE?"
    }
  }
}

# --- Cred store --------------------------------------------------------
#
# Single region, no replication, no PITR, no deletion protection — dev
# data is fully throwaway.

module "creds_table" {
  source = "../../modules/dynamodb-creds-table"

  name = "meandr-creds-development"

  pitr_enabled                = false
  deletion_protection_enabled = false

  tags = local.tags
}

module "cred_encryption_key" {
  source = "../../modules/cred-encryption-key"

  env        = "development"
  alias_name = "meandr-cred-development"

  enable_key_rotation     = true
  deletion_window_in_days = 7

  tags = local.tags
}

# --- Cred-store IAM policy on the dev user -----------------------------
#
# The user itself is created in account-development/. We look it up by
# name (stable) and attach a region-resource-scoped policy here. This
# is the dev equivalent of the per-app task-role policies in staging /
# production — one human running both BE and proxy locally needs the
# union of both scopes (R/W on the table, GenerateDataKey + Decrypt on
# the CMK, CRUD on the dated SM key path).

data "aws_iam_user" "dev" {
  user_name = "meandr-dev"
}

resource "aws_iam_user_policy" "dev_cred_store" {
  name = "cred-store-access"
  user = data.aws_iam_user.dev.user_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoCredTableReadWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable",
          "dynamodb:ListTables",
        ]
        Resource = module.creds_table.table_arn
      },
      {
        Sid    = "KMSCredEncryption"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = module.cred_encryption_key.key_arn
      },
    ]
  })
}

# --- Outputs ------------------------------------------------------------

output "creds_table_name" {
  description = "Dev cred-store Dynamo table name. Set as MEANDR_CRED_TABLE_NAME in local .env."
  value       = module.creds_table.table_name
}

output "creds_table_arn" {
  description = "Dev cred-store Dynamo table ARN."
  value       = module.creds_table.table_arn
}

output "cred_encryption_key_alias" {
  description = "Dev cred-store KMS alias (full form, including `alias/`). Set as MEANDR_CRED_KMS_KEY_ALIAS in local .env."
  value       = module.cred_encryption_key.alias_name
}

output "cred_encryption_key_arn" {
  description = "Dev cred-store KMS CMK ARN."
  value       = module.cred_encryption_key.key_arn
}
