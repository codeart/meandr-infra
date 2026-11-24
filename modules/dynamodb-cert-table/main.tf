# Workspace hostnames' certificates, one row per cert_ref, written once by BE
# and read by every region's proxy (docs/contracts/cert_store.md §4.1).

resource "aws_dynamodb_table" "main" {
  name         = var.name
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "cert_ref"

  attribute {
    name = "cert_ref"
    type = "S"
  }

  point_in_time_recovery {
    enabled = var.pitr_enabled
  }

  # The key is sealed under the cert CMK at the app layer.
  server_side_encryption {
    enabled = true
  }

  deletion_protection_enabled = var.deletion_protection_enabled

  # The stream makes it replicable; an edge declares its own replica, as for the cred table.
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  tags = merge(var.tags, {
    Name = var.name
  })

  lifecycle {
    ignore_changes = [
      tags["aws:dynamodb:tableArn"],
      replica, # edge-declared replicas; without this the primary destroys them
    ]
  }
}
