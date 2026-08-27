# Replicas of multi-Region CMKs, declared by the region that needs them.
#
# The primary makes a key REPLICABLE (multi_region = true) without naming
# any region; this is the other half. Same key material and key id, so
# ciphertext written in either region opens in both — the requirement,
# since Decrypt resolves the key from the blob and a regional key does not
# exist at another endpoint.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.24"
      configuration_aliases = [aws.primary]
    }
  }
}

data "aws_kms_key" "primary" {
  for_each = var.keys

  provider = aws.primary
  key_id   = "alias/${each.key}"
}

resource "aws_kms_replica_key" "this" {
  for_each = var.keys

  description             = each.value
  primary_key_arn         = data.aws_kms_key.primary[each.key].arn
  deletion_window_in_days = var.deletion_window_in_days

  tags = var.tags
}

# Same alias as the primary carries, so callers name one string in every
# region and it resolves locally.
resource "aws_kms_alias" "this" {
  for_each = var.keys

  name          = "alias/${each.key}"
  target_key_id = aws_kms_replica_key.this[each.key].key_id
}
