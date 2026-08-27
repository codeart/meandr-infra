# One table per env holding AEAD-encrypted per-server credential blobs.
# BE writes, proxy reads. Item shape and the Ruby<->Go wire format are in
# docs/credential_store.md.
#
# No GSIs: the only access pattern is GetItem by server_uuid.

resource "aws_dynamodb_table" "main" {
  name         = var.name
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "server_uuid"

  attribute {
    name = "server_uuid"
    type = "S"
  }

  point_in_time_recovery {
    enabled = var.pitr_enabled
  }

  server_side_encryption {
    enabled = true
    # AWS-managed key. The app-layer AES-256-GCM is the real control; the
    # customer-managed CMK sits at the envelope layer
    # (modules/cred-encryption-key).
  }

  deletion_protection_enabled = var.deletion_protection_enabled

  # Off deliberately: an expiring item would remove a cred without the
  # proxy being notified. Revocation is a BE delete plus a version bump.
  ttl {
    enabled        = false
    attribute_name = ""
  }

  # Always on, because it is what makes the table REPLICABLE without naming
  # who replicates it — Global Tables V2 is fed by the stream.
  #
  # NO `replica` blocks on purpose. An edge declares itself with
  # aws_dynamodb_table_replica in its OWN state, so a region is added or
  # removed without touching this one. The two forms are mutually
  # exclusive. Nothing reads the stream until a replica exists.
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  # A replica is useless unless the cred CMK is multi-Region: decrypt
  # resolves the key named in the blob, so an edge would hold rows it
  # cannot read and fail every authenticated upstream call.

  tags = merge(var.tags, {
    Name = var.name
  })

  lifecycle {
    ignore_changes = [
      # Rewritten by AWS auto-tagging on busy tables.
      tags["aws:dynamodb:tableArn"],

      # REQUIRED for edge-declared replicas. This block is authoritative,
      # so without it the primary plans to destroy every replica it does
      # not itself declare — undoing the edge on the next apply here.
      replica,
    ]
  }
}
