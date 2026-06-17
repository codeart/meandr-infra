# meandr-mcp orchestrator — proxy stack for a region.
#
# Owns: writer Valkey (per-region, no replication) + NLB + ACM (*.meandr.io)
#       + ECS cluster + proxy service + wildcard DNS.
#
# Reader Valkey is created at the region-caller level (because meandr-api also
# uses it). meandr-mcp takes its endpoint as input.

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
# meandr-mcp consume it). We take its two AWS-managed endpoints as
# separate inputs so the proxy can pick the right one per use case:
#
#   - config_reader_endpoint (replica): pure config-record reads.
#     Tolerates replication lag; takes load off the primary; in multi-AZ
#     production this endpoint refuses writes at the AWS layer, which is
#     a useful safety boundary.
#
#   - config_writer_endpoint (primary): inbound stream consumption
#     (XREADGROUP on `<env>:in`). Group state is a write op, so this MUST
#     be the primary even though the app is "reading."
#
# Both AWS hostnames are passed directly (no CNAME alias) so the
# cluster's wildcard TLS cert verifies cleanly.

variable "config_reader_endpoint" {
  description = "Reader (replica) endpoint of `meandr-config-stream`. AWS-internal hostname. Proxy uses this for config-record reads only — XREADGROUP on the inbound stream needs the writer endpoint."
  type        = string
}

variable "config_writer_endpoint" {
  description = "Writer (primary) endpoint of `meandr-config-stream`. AWS-internal hostname. Proxy uses this for inbound stream consumption (`<env>:in`). In multi-AZ production this is the only endpoint that accepts writes — including the XREADGROUP group-state writes that stream consumption produces."
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
