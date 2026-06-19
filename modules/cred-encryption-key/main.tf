# KMS CMK for envelope-encrypting server credentials.
#
# Role in the cred-store architecture (see docs/credential_store.md for
# the full picture):
#
#   ┌──────────┐  KMS.GenerateDataKey   ┌──────────┐
#   │    BE    │ ─────────────────────► │   KMS    │
#   │  (Rails) │ ◄───────────────────── │   CMK    │  ← this module
#   └──────────┘  {Plaintext, Wrapped}  └──────────┘
#         │                                  ▲
#         │ uses Plaintext for AES-256-GCM   │
#         │ encryption of the cred JSON,     │
#         │ stores Wrapped in SM under       │
#         │ meandr/mcp/<env>/key/<date>      │
#         ▼                                  │
#   ┌──────────┐                             │
#   │  Dynamo  │  blob = nonce||ct||tag      │
#   │  table   │  key_version = "<date>"     │
#   └──────────┘                             │
#         ▲                                  │
#         │ GetItem on cred-version-change   │
#   ┌──────────┐                             │
#   │  Proxy   │  reads SM at key_version,   │
#   │   (Go)   │  KMS.Decrypt(Wrapped) ──────┘
#   └──────────┘  → Plaintext data key,
#                 decrypts blob locally,
#                 caches plaintext key in memory by key_version
#
# The CMK itself never encrypts the cred JSON directly. That keeps KMS
# call volume tiny: one Decrypt per (proxy boot × key_version), not per
# request. Rotation of the dated data key is a Rails task that
# generates a fresh data key from this CMK and writes a new dated SM
# secret; the CMK is the long-lived root.
#
# CMK material rotates annually (KMS-native rotation; transparent to
# all callers — KMS keeps old material for decrypts of pre-rotation
# wrapped data keys). To force a more aggressive rotation we'd create
# a new CMK + repoint the data-key generation pipeline; not needed
# at this scale.

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "main" {
  description             = "AEAD envelope key for ${var.env} server credentials (meandr-cred-${var.env})"
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = var.enable_key_rotation
  multi_region            = var.multi_region

  # Key policy: root account gets full admin (the documented AWS-default
  # fallback so we don't lock ourselves out of the key — without this
  # the CMK becomes unmanageable if its only delegated principals are
  # ever deleted). App-side permissions (BE GenerateDataKey, proxy
  # Decrypt) attach via IAM role policies in the consuming modules —
  # those reference this key's ARN by output, so adding/removing apps
  # is an IAM change, not a key-policy change.
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
