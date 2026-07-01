# KMS CMK for envelope-encrypting tool-call payloads gated by approval.
#
# Distinct from cred-encryption-key (which wraps DEKs for server credential
# storage in DynamoDB) — different data classification, different IAM
# scoping, different rotation policy potentially. Separate CMK keeps the
# audit trail clean and lets each key rotate on its own schedule.
#
# Role in the approval-flow architecture (see events/flows/approval-required.md
# for the full picture):
#
#   ┌──────────┐  KMS.GenerateDataKey  ┌──────────┐
#   │   Proxy  │ ────────────────────► │   KMS    │
#   │   (Go)   │ ◄──────────────────── │   CMK    │  ← this module
#   └──────────┘  {Plaintext, Wrapped} └──────────┘
#         │                                 ▲
#         │ uses Plaintext for AES-256-GCM  │
#         │ encryption of the request body, │
#         │ then wipes plaintext from mem   │
#         │ ships {iv, ct, tag, wrapped} to │
#         │ BE via audit.tool.action.required
#         ▼                                 │
#   ┌──────────┐                            │
#   │    BE    │  Stores the opaque blob    │
#   │  (Rails) │  as-is in                  │
#   └──────────┘  project_tool_actions.     │
#         │                                 │
#         │ On admin.tool.action.approve,   │
#         │ ships the blob back through the │
#         │ eventbus to the proxy for exec  │
#         ▼                                 │
#   ┌──────────┐                            │
#   │  Proxy   │  KMS.Decrypt(wrapped) ─────┘
#   │   (Go)   │  → Plaintext data key,
#   └──────────┘  decrypts blob locally,
#                 executes upstream call,
#                 wipes plaintext from mem
#
# Separately, BE has kms:Decrypt permission on this key — used ONLY by
# the dashboard "view action payload" endpoint. Each such call generates
# an audit log entry visible to the customer ("user X viewed action Y
# payload at Z"). BE never routinely calls KMS for approval-flow data;
# only on explicit user action.
#
# Envelope encryption keeps KMS call volume proportional to actions (not
# requests): one GenerateDataKey per action-created + one Decrypt per
# action-executed + occasional Decrypt on dashboard view. At target
# scale (~100M actions/mo → ~200M KMS calls/mo → ~$60/mo), the cost is
# negligible.
#
# CMK material rotates annually (KMS-native rotation; transparent to
# all callers — KMS keeps old material for decrypts of pre-rotation
# wrapped data keys).

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "main" {
  description             = "AEAD envelope key for ${var.env} approval-flow tool-call payloads (meandr-payload-${var.env})"
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = var.enable_key_rotation
  multi_region            = var.multi_region

  # Key policy: root account gets full admin (the documented AWS-default
  # fallback so we don't lock ourselves out of the key). App-side
  # permissions (proxy GenerateDataKey + Decrypt, BE Decrypt) attach via
  # IAM role policies in the consuming modules — those reference this
  # key's ARN by output, so adding/removing apps is an IAM change, not
  # a key-policy change.
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
    Name = "meandr-payload-${var.env}"
  })
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.alias_name}"
  target_key_id = aws_kms_key.main.key_id
}
