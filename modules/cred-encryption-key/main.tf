# CMK for server credentials. BE encrypts each blob directly with
# KMS.Encrypt(KeyId=alias); there is no data-key layer and nothing to
# bootstrap. Contract: docs/credential_store.md.

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "main" {
  description             = "AEAD envelope key for ${var.env} server credentials (meandr-cred-${var.env})"
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = var.enable_key_rotation
  multi_region            = var.multi_region

  # Root-only. App permissions attach via IAM in consuming modules, so
  # adding an app is an IAM change rather than a key-policy change.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "EnableIAMUserPermissions"
      Effect = "Allow"
      Principal = {
        AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      }
      Action   = "kms:*"
      Resource = "*"
    }]
  })

  tags = merge(var.tags, {
    Name = "meandr-cred-${var.env}"
  })
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.alias_name}"
  target_key_id = aws_kms_key.main.key_id
}
