variable "name" {
  description = "Logical name for the cluster. Used as the AWS replication-group id and in Name tags. Keep short (e.g. `meandr-reader`, `meandr-writer`). Max 40 chars per AWS limit."
  type        = string

  validation {
    condition     = length(var.name) <= 40
    error_message = "ElastiCache replication group ID has a 40-char limit."
  }
}

variable "description" {
  description = "Human-readable description for the cluster. Shown in the AWS console; helps the operator distinguish reader from writer at a glance."
  type        = string
}

variable "role" {
  description = "Either `reader` or `writer`. Drives the DNS record name (`redis-reader.<env>.meandr.local` vs `redis-writer.<env>.meandr.local`)."
  type        = string

  validation {
    condition     = contains(["reader", "writer"], var.role)
    error_message = "role must be `reader` or `writer`."
  }
}

variable "engine_version" {
  description = "Valkey engine version. `8.1` is the current default — has per-field hash TTL (HEXPIRE) which meandr's rate-limit + cache layers will eventually use. AWS supports 7.2 / 8.0 / 8.1 as of 2025."
  type        = string
  default     = "8.1"
}

variable "node_type" {
  description = "ElastiCache node type. Staging default: `cache.t4g.micro` (~$11/mo). Production reader will need `cache.r7g.large` or similar to be Global-Datastore-eligible (T-family is NOT eligible for GD)."
  type        = string
  default     = "cache.t4g.micro"
}

variable "num_cache_clusters" {
  description = "Number of nodes in the replication group. 1 = primary only (no replicas). 2+ = primary + read replicas. Staging stays at 1; production reader should be 2+ for failover."
  type        = number
  default     = 1
}

variable "automatic_failover_enabled" {
  description = "Automatic failover requires num_cache_clusters >= 2. Force-false for staging single-node deployments."
  type        = bool
  default     = false
}

variable "multi_az_enabled" {
  description = "Multi-AZ for failover. Requires automatic_failover_enabled = true and num_cache_clusters >= 2. Off for staging."
  type        = bool
  default     = false
}

variable "transit_encryption_enabled" {
  description = "TLS in-transit. **Required for Global Datastore eligibility** — turning this on later requires a full rebuild. On for readers (GD-ready posture); off for writers (regional-only, never in GD)."
  type        = bool
}

variable "at_rest_encryption_enabled" {
  description = "Encrypt the on-disk RDB / AOF snapshots. Default-on; minor cost overhead."
  type        = bool
  default     = true
}

variable "snapshot_retention_days" {
  description = "Daily RDB snapshots kept. 0 disables snapshots. Default 1 for staging (cheap insurance); production reader: 7+."
  type        = number
  default     = 1
}

variable "vpc_id" {
  description = "VPC to place the cluster into. From vpc module output."
  type        = string
}

variable "vpc_cidr_block" {
  description = "VPC CIDR. Source for the cluster's SG ingress rule on port 6379."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs the cache subnet group spans. ElastiCache requires ≥2 subnets across distinct AZs (same constraint as RDS)."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "ElastiCache subnet group requires subnets in at least 2 AZs."
  }
}

variable "internal_dns_zone_id" {
  description = "Route 53 private hosted zone ID. CNAME `redis-<role>.<env>.meandr.local` → primary endpoint."
  type        = string
}

variable "internal_dns_zone_name" {
  description = "Internal DNS zone name (e.g. `staging.meandr.local`)."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}
