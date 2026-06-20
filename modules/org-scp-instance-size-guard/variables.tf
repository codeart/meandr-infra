variable "name" {
  description = "Logical name. Becomes the SCP name; visible in Organizations console."
  type        = string
}

variable "target_ids" {
  description = "List of Root / OU / Account IDs to attach the SCP to. Pass the Root ID (e.g., r-xxxx) to apply org-wide; pass OU IDs for narrower scopes. The Organizations master account is exempt regardless of attachment — SCPs cannot constrain it by design."
  type        = list(string)

  validation {
    condition     = length(var.target_ids) > 0
    error_message = "At least one target_id is required — an SCP with no attachments is dead code."
  }
}

variable "denied_instance_patterns" {
  description = "Patterns (StringLike syntax) for EC2 instance types that should be denied at RunInstances/ModifyInstanceAttribute time. Default mirrors the iam-instance-size-guard module: anything 4xlarge and up plus the bare-metal SKUs."
  type        = list(string)
  default = [
    "*.4xlarge",
    "*.6xlarge",
    "*.8xlarge",
    "*.9xlarge",
    "*.10xlarge",
    "*.12xlarge",
    "*.16xlarge",
    "*.18xlarge",
    "*.24xlarge",
    "*.32xlarge",
    "*.48xlarge",
    "*.metal",
    "*.metal-*",
  ]
}

variable "denied_rds_class_patterns" {
  description = "Patterns for RDS instance classes denied at CreateDBInstance/ModifyDBInstance time. Format `db.<family>.<size>`."
  type        = list(string)
  default = [
    "db.*.4xlarge",
    "db.*.6xlarge",
    "db.*.8xlarge",
    "db.*.10xlarge",
    "db.*.12xlarge",
    "db.*.16xlarge",
    "db.*.24xlarge",
    "db.*.32xlarge",
  ]
}

variable "denied_elasticache_node_patterns" {
  description = "Patterns for ElastiCache node types denied at CreateCacheCluster/CreateReplicationGroup/ModifyReplicationGroup time. Format `cache.<family>.<size>`."
  type        = list(string)
  default = [
    "cache.*.4xlarge",
    "cache.*.8xlarge",
    "cache.*.12xlarge",
    "cache.*.16xlarge",
    "cache.*.24xlarge",
  ]
}

variable "description" {
  description = "Free-form text shown on the SCP in the Organizations console. Operator-readable explanation of why this policy exists + how to bypass."
  type        = string
  default     = "Org-wide deny of large/metal instance types across EC2 / RDS / ElastiCache. Bypass: edit pattern lists in TF + re-apply, or detach this SCP from the target in the Organizations console (CloudTrail captures the detach)."
}

variable "tags" {
  description = "Tags applied to the SCP resource."
  type        = map(string)
  default     = {}
}
