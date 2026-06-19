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

# NB: This module deliberately does NOT create any DNS records. The caller
# owns Route 53 records pointing at the cluster's `primary_endpoint_address`
# (writes) and `reader_endpoint_address` (reads). Each consumer app uses
# its own prefix (e.g. `mcp-redis-in/out` for the proxy, `be-redis-in/out`
# for BE) even when the underlying cluster is shared, which keeps each
# app's connection string app-local and lets us split clusters later
# without touching app config.

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

variable "parameter_group_family" {
  description = "Parameter-group family — must match the major of engine_version (`valkey8` for 8.x, `valkey7` for 7.x). When bumping engine to a new major, bump this too."
  type        = string
  default     = "valkey8"
}

variable "maxmemory_policy" {
  description = "Eviction policy. ElastiCache's default-of-defaults is `volatile-lru`, which silently evicts keys with TTLs when memory pressure hits — bad for our planes (config records must not vanish; cable subscriptions must not vanish; counter keys are TTL'd by design and would be the first targets of volatile-lru). `noeviction` lets the cluster surface OOM as an error the caller can handle, which is what we want everywhere."
  type        = string
  default     = "noeviction"

  validation {
    condition = contains([
      "noeviction", "volatile-lru", "allkeys-lru", "volatile-lfu", "allkeys-lfu",
      "volatile-random", "allkeys-random", "volatile-ttl",
    ], var.maxmemory_policy)
    error_message = "Unsupported maxmemory_policy. See AWS ElastiCache Valkey docs for allowed values."
  }
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

# internal_dns_zone_id / internal_dns_zone_name removed — DNS is caller-owned.

variable "auth_token" {
  description = "Optional AUTH token (Redis 6+ AUTH). When set, the cluster requires authentication on every connection — clients must pass this token via the `requirepass` / Password field. Network isolation (private subnets + SG ingress) remains the primary trust boundary; AUTH is defense-in-depth. Token must be 16-128 printable ASCII chars. When changing on an existing cluster, set `auth_token_update_strategy` accordingly. Empty string disables AUTH."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.auth_token == "" || (length(var.auth_token) >= 16 && length(var.auth_token) <= 128)
    error_message = "auth_token must be 16-128 chars (or empty to disable)."
  }
}

variable "auth_token_update_strategy" {
  description = "How AWS rotates the AUTH token when its value changes. `ROTATE` (default) accepts BOTH old and new tokens during the rollout window — required when enabling AUTH on an existing cluster or swapping the token, otherwise live clients fail mid-flight. `SET` switches in one shot (only safe on first creation). `DELETE` removes AUTH. ElastiCache docs: a single ROTATE → SET sequence is the canonical zero-downtime AUTH enablement."
  type        = string
  default     = "ROTATE"

  validation {
    condition     = contains(["SET", "ROTATE", "DELETE"], var.auth_token_update_strategy)
    error_message = "auth_token_update_strategy must be one of SET, ROTATE, DELETE."
  }
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}
