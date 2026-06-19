# meandr-mcp orchestrator — proxy stack for a region.
#
# Owns: event-stream Valkey (per-region, no replication) + NLB + ECS
#       cluster + proxy service + wildcard `*.<dns_zone_name>` DNS.
#
# Config-stream Valkey is created at the region-caller level (because
# meandr-api also uses it). meandr-mcp takes its endpoint as input.

# --- Identity / placement -----------------------------------------------

variable "env" {
  description = "Environment: `staging` or `production`. Drives tag values and naming."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.env)
    error_message = "env must be staging or production."
  }
}

variable "account_id" {
  description = "Expected AWS account ID — account_guard precondition."
  type        = string
}

# --- VPC inputs ---------------------------------------------------------

variable "vpc_id" {
  description = "VPC the stack runs in."
  type        = string
}

variable "vpc_cidr_block" {
  description = "VPC CIDR (for SG ingress rules)."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets — used by NLB."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnets — used by writer Valkey and proxy ECS tasks."
  type        = list(string)
}

variable "internal_dns_zone_id" {
  description = "Route 53 private hosted zone ID for the writer Valkey CNAME."
  type        = string
}

variable "internal_dns_zone_name" {
  description = "Internal zone name (e.g. `staging.meandr.local`)."
  type        = string
}

# --- Config-stream Valkey (created at region level; consumed here) -----
#
# The config-stream cluster lives at region level (both meandr-api and
# meandr-mcp consume it). The proxy is *read-only* on this cluster:
#
#   - tenant.RedisSource — GET / HGET / HGETALL of config records.
#   - eventbus inbound listener — plain XREAD (NOT XREADGROUP) with a `$`
#     cursor on `<env>:in`.
#
# Both are pure read ops, so the AWS reader (replica) endpoint serves
# them. We deliberately do NOT pass the primary endpoint — the proxy
# never writes here. The XREAD-not-XREADGROUP design is load-bearing:
# every proxy reads the whole stream independently (fan-out), and
# routing/dedup happens at the proxy layer via the envelope's
# `region` / `node` / `uni` fields plus a SETNX claim on the event
# cluster. If you ever switch to XREADGROUP (per-proxy acked delivery),
# you must also switch this variable's source to the primary endpoint.
# See meandr-mcp's app.Config.ConfigReader for the full rationale.
#
# The AWS hostname is passed directly (no CNAME alias) so the cluster's
# wildcard TLS cert verifies cleanly.

variable "config_reader_endpoint" {
  description = "Reader (replica) endpoint of `meandr-config-stream`. AWS-internal hostname. Proxy uses this for ALL config-stream traffic: config-record reads + inbound `<env>:in` XREAD. The replica is correct because every operation on this cluster is read-only — see the comment above for the load-bearing reasoning."
  type        = string
}

# --- Public DNS ---------------------------------------------------------

variable "dns_zone_name" {
  description = "Public Route 53 hosted zone name (in Shared account). Wildcard `*.<zone>` A-alias points at the NLB."
  type        = string
  default     = "meandr.io"
}

# TLS termination is deferred — the proxy will eventually terminate TLS
# itself using a cert acquired via Let's Encrypt DNS-01 (BE-side job
# orders + renews, uploads to Secrets Manager, emits a config event the
# proxy listens for). Until that pipeline lands, NLB exposes two plain
# TCP listeners (80 + 443); HTTPS clients see a handshake failure, which
# is the expected v0 state.

# --- Image --------------------------------------------------------------

variable "ecr_registry" {
  description = "ECR registry URL."
  type        = string
  default     = "303529433558.dkr.ecr.eu-central-1.amazonaws.com"
}

variable "image_repository" {
  description = "ECR repo name for the proxy."
  type        = string
  default     = "meandr-mcp"
}

variable "image_tag" {
  description = "Mutable image tag. `develop` for staging, `main` for production. CI pushes new SHAs under this tag."
  type        = string
  default     = "develop"
}

# --- Redis AUTH (shared token across config-stream + event-stream) -----
#
# Caller owns the random_password + aws_secretsmanager_secret resources
# and passes (plaintext, secret_arn) here. Plaintext goes to the
# event-stream cluster's auth_token; secret ARN goes to the proxy task
# def secrets so it reads MEANDR_REDIS_*_PASSWORD at boot. Same token
# also wired to config-stream + api-redis from their region-level
# callers — single token, single rotation lever per env.

variable "redis_auth_enabled" {
  description = "Explicit on/off gate for Redis AUTH wiring on the proxy side. Separate from redis_auth_secret_arn because `count` on the conditional IAM policy needs a known-at-plan-time value, and the ARN of a not-yet-created SM secret isn't. Set true alongside non-empty redis_auth_token + redis_auth_secret_arn; false leaves AUTH disabled and the secret wiring inert."
  type        = bool
  default     = false
}

variable "redis_auth_token" {
  description = "Plaintext Redis AUTH token. Passed to the event-stream cluster's auth_token attribute when redis_auth_enabled = true; ignored otherwise."
  type        = string
  default     = ""
  sensitive   = true
}

variable "redis_auth_secret_arn" {
  description = "ARN of the SM secret holding the same AUTH token. Wired into the proxy task def as MEANDR_REDIS_CONFIG_READER_PASSWORD + MEANDR_REDIS_EVENT_WRITER_PASSWORD when redis_auth_enabled = true so the proxy authenticates to both Redis planes with one shared token."
  type        = string
  default     = ""
}

# --- Credential store (proxy is read-only) -----------------------------
#
# `cred_store_enabled` gates the IAM policy count separately from the
# ARN value because `count` needs a known-at-plan-time bool — same
# pattern as redis_auth_enabled above.

variable "cred_store_enabled" {
  description = "Explicit on/off gate for cred-store wiring on the proxy side. Set true alongside the table_arn + key_arn inputs; false leaves the env vars empty and the IAM policy absent."
  type        = bool
  default     = false
}

#
# Proxy side of the cred-store architecture. Reads AES-256-GCM blobs
# from the cred Dynamo table on cred-version-change events, decrypts
# locally with a data key it fetches from the dated SM secret + unwraps
# via KMS. See docs/credential_store.md for the full architecture.
#
# IAM is strictly narrower than the BE side: GetItem on Dynamo (no
# writes), GetSecretValue on the SM path (no creates), Decrypt on the
# CMK (no GenerateDataKey — only BE mints data keys).

variable "creds_table_name" {
  description = "DynamoDB cred-store table name. Goes into MEANDR_CRED_TABLE_NAME for the proxy. Empty disables cred-store wiring on the proxy side."
  type        = string
  default     = ""
}

variable "creds_table_arn" {
  description = "DynamoDB cred-store table ARN. Used to scope the task role's DynamoDB GetItem policy to this specific table."
  type        = string
  default     = ""
}

variable "cred_encryption_key_arn" {
  description = "KMS CMK ARN. Proxy calls KMS.Decrypt against it to unwrap data keys fetched from SM. No GenerateDataKey permission — that's BE-only."
  type        = string
  default     = ""
}

variable "cred_sm_secret_path_prefix" {
  description = "SM secret path prefix for the dated wrapped data keys, e.g. `meandr/mcp/staging/key`. Proxy reads SM secrets like `<prefix>/<date>` when it encounters a previously-unseen key_version on a Dynamo blob. Used to scope the task role's SM IAM policy."
  type        = string
  default     = ""
}

# --- Event-stream Valkey sizing ----------------------------------------

variable "event_stream_node_type" {
  description = "ElastiCache node type for the event-stream cluster. Single-region (never in GD), so any node family works including T-family."
  type        = string
  default     = "cache.t4g.micro"
}

variable "event_stream_replicas" {
  description = "num_cache_clusters for the event-stream cluster. 1 = single node, no replication."
  type        = number
  default     = 1
}

variable "event_stream_snapshot_retention_days" {
  description = "Daily RDB snapshots for the event-stream cluster. 1 for staging; consider 7+ for production."
  type        = number
  default     = 1
}

# --- Proxy service sizing -----------------------------------------------

variable "proxy" {
  description = "Sizing + replica bounds for the proxy. desired_count = 0 means the service is provisioned but idle — useful when the image isn't ready yet."
  type = object({
    cpu                    = number
    memory                 = number
    desired_count          = number
    min_replicas           = number
    max_replicas           = number
    target_cpu_utilization = number
  })
  default = {
    cpu                    = 256
    memory                 = 512
    desired_count          = 0
    min_replicas           = 0
    max_replicas           = 8
    target_cpu_utilization = 60
  }
}

variable "proxy_port" {
  description = "Plain-HTTP TCP port the proxy listens on. NLB :80 forwards here."
  type        = number
  default     = 8080
}

variable "proxy_tls_port" {
  description = "TLS port the proxy listens on. NLB :443 forwards here. Unprivileged (>1024) because the distroless `nonroot` user can't bind <1024."
  type        = number
  default     = 8443
}

# --- Logging ------------------------------------------------------------

variable "log_level" {
  description = "Proxy log level. `info` for staging/production; `debug` only for active triage. The proxy validates against trace|debug|info|warn|error|fatal."
  type        = string
  default     = "info"
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 30
}

# --- Tags ---------------------------------------------------------------

variable "extra_tags" {
  description = "Extra tags merged into every resource."
  type        = map(string)
  default     = {}
}
