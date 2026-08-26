variable "name" {
  description = "Logical name for the table — used as the AWS table name and in Name tags. Convention: `meandr-creds-<env>`. The cred-store is one table per env (not per region); replication across regions is via Global Tables, not separate tables."
  type        = string

  validation {
    condition     = length(var.name) <= 255 && can(regex("^[a-zA-Z0-9_.-]+$", var.name))
    error_message = "DynamoDB table name must be ≤255 chars and match [a-zA-Z0-9_.-]+."
  }
}

# `replica_regions` was removed deliberately. Replicas are declared by the
# EDGE, in the edge's own state, with `aws_dynamodb_table_replica` pointing
# at this table's ARN — so adding a region never edits the primary. The
# table is made replicable here (streams) without knowing who replicates it.

variable "pitr_enabled" {
  description = "Point-in-time recovery. Keeps 35 days of continuous backups; lets the operator restore to any second in that window. On for production (cred rotations are audit-relevant + irreversible if blob is lost); off for staging / dev (cheap insurance not worth the cost when the data is throwaway)."
  type        = bool
  default     = false
}

variable "deletion_protection_enabled" {
  description = "Block accidental destroy on the table itself. Independent from PITR — this protects against a `terraform destroy` of the wrong env, not against data loss inside the table. On for production; off for staging / dev to allow easy teardown."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags applied to the table."
  type        = map(string)
  default     = {}
}
