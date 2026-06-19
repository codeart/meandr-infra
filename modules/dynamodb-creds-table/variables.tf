variable "name" {
  description = "Logical name for the table — used as the AWS table name and in Name tags. Convention: `meandr-creds-<env>`. The cred-store is one table per env (not per region); replication across regions is via Global Tables, not separate tables."
  type        = string

  validation {
    condition     = length(var.name) <= 255 && can(regex("^[a-zA-Z0-9_.-]+$", var.name))
    error_message = "DynamoDB table name must be ≤255 chars and match [a-zA-Z0-9_.-]+."
  }
}

variable "replica_regions" {
  description = "Additional regions to add as Global Tables replicas. Empty for single-region setups (staging today, dev always). When production adds a second proxy region, add it here — the existing table becomes the leader, the new region gets an asynchronously-replicated replica. ElastiCache region naming (e.g. `us-east-1`)."
  type        = list(string)
  default     = []
}

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
