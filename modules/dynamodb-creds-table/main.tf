# DynamoDB cred-store table.
#
# One table per env, optionally replicated across regions via Global
# Tables. Stores per-server AEAD-encrypted credential blobs that ride
# alongside the Server config — see docs/credential_store.md for the
# full architecture and the Ruby↔Go wire format. Only the BE writes;
# only the proxy reads.
#
# Item shape:
#   - server_uuid     (S)  ← partition key, the Server's UUIDv7 from PG
#   - blob            (B)  ← nonce ‖ ciphertext ‖ tag (AES-256-GCM)
#   - cred_version    (N)  ← monotonic; bumped by BE on every cred write
#   - key_version     (S)  ← matches the dated SM secret used to encrypt
#                            (e.g. "2026-06-19") so the proxy can fetch
#                            the right wrapped data key for decrypt
#   - updated_at      (S)  ← ISO 8601, written by BE for audit
#
# No GSIs. The only access pattern is "give me the cred for this
# server_uuid" — that's the PK GetItem path, single-digit ms. The BE
# never scans; the proxy never lists. Sparse keyspace, low write rate
# (rotations only), low read rate (cred-version-bump events only).
#
# Capacity = PAY_PER_REQUEST. Bills per 1M read+write, no min charge.
# At our expected volume (thousands of servers, rotations measured in
# hours/days) this is pennies/month.
#
# Encryption at rest = AWS-managed key. The app-layer AES-256-GCM is
# the real protection (a leaked dynamo backup yields ciphertext that's
# useless without the SM-wrapped data key), so a customer-managed CMK
# here doesn't add a meaningful control. We use a customer-managed CMK
# at the *envelope* layer (see modules/cred-encryption-key), which is
# where it matters.

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
    # No `kms_key_arn` → AWS-managed key. App-layer AEAD is the real
    # control; AWS-managed at-rest gets us compliance posture for free.
  }

  deletion_protection_enabled = var.deletion_protection_enabled

  # TTL is off. Cred blobs are not time-bound; they're replaced by
  # rotation. If TTL were on and we ever set `expires_at` on items, a
  # cred could vanish without the proxy being notified — bad failure
  # mode. Lifecycle stays explicit (BE deletes + bumps cred_version
  # on revoke).
  ttl {
    enabled        = false
    attribute_name = ""
  }

  # Always on, because it is what makes the table REPLICABLE without
  # naming who replicates it. Global Tables V2 is fed BY the stream, so a
  # replica cannot exist without one in NEW_AND_OLD_IMAGES.
  #
  # This table has no `replica` blocks on purpose. An edge declares
  # itself with `aws_dynamodb_table_replica` in its OWN state, pointing
  # at this table's ARN — so the primary never holds a list of its edges,
  # and a region is added or removed without touching this one. The two
  # forms are mutually exclusive; adding `replica` here would fight it.
  #
  # Streams are billed per read, and nothing reads this one until a
  # replica exists, so leaving it on costs nothing.
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  # NOTE: a replica is useless unless the cred CMK is multi-Region.
  # Decrypt resolves the key from the ciphertext blob, and that blob
  # names a REGIONAL key — an edge holding replicated rows it cannot
  # decrypt fails every authenticated upstream call.

  tags = merge(var.tags, {
    Name = var.name
  })

  # Description text on the table itself doesn't exist — DynamoDB has
  # no description field. Tags and naming carry the meaning.
  lifecycle {
    ignore_changes = [
      # Item count tags get rewritten by AWS auto-tagging on busy
      # tables; suppressing keeps `terraform plan` clean.
      tags["aws:dynamodb:tableArn"],
    ]
  }
}
