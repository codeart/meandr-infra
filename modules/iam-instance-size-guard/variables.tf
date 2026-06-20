variable "name" {
  description = "Logical name. Becomes the IAM policy name; visible in the console."
  type        = string
}

variable "denied_instance_patterns" {
  description = "Patterns (StringLike syntax) for EC2 instance types that should be denied at RunInstances/ModifyInstanceAttribute time. Default catches the genuine fat-finger giants — anything 4xlarge and up plus the bare-metal SKUs — without blocking normal iteration (t4g.small → t4g.medium → m5.large still all allowed). Customize per-env if production ever has a legitimate `8xlarge` use case."
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
  description = "Patterns for RDS instance classes denied at CreateDBInstance/ModifyDBInstance time. Same shape as the EC2 list — `db.<family>.<size>` so the same suffix patterns work."
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
  description = "Free-form text shown on the IAM policy + console. Operator-readable explanation of why this policy exists."
  type        = string
  default     = "Deny accidental spin-up of large/metal instance types across EC2 / RDS / ElastiCache. Bypass by updating the patterns input."
}
