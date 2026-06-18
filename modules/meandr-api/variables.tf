# meandr-api orchestrator — every input the module needs to stand up the full
# Rails BE stack in a region. A per-region caller's job is to provide values
# for these; everything else is module-internal.

# --- Identity / placement -----------------------------------------------

variable "env" {
  description = "Environment: `staging` or `production`. Drives Redis URL hostnames, DB name, Secrets Manager paths, tag values, internal DNS zone."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.env)
    error_message = "env must be staging or production."
  }
}

variable "account_id" {
  description = "Expected AWS account ID — for account_guard precondition."
  type        = string
}

# --- VPC inputs (region caller provides; module doesn't own VPC) -------

variable "vpc_id" {
  description = "VPC the stack runs in. Caller creates VPC separately and passes its ID."
  type        = string
}

variable "vpc_cidr_block" {
  description = "VPC CIDR (for SG ingress rules that allow intra-VPC traffic)."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets — used by ALB."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnets — used by RDS, Valkey, ECS tasks."
  type        = list(string)
}

variable "internal_dns_zone_id" {
  description = "Route 53 private hosted zone ID (e.g. `Z025315720344B5RP91LR`). RDS and Valkey CNAMEs land here."
  type        = string
}

variable "internal_dns_zone_name" {
  description = "Internal zone name (e.g. `staging.meandr.local`). Suffix for CNAMEs."
  type        = string
}

# --- Public hostname + cert ---------------------------------------------

variable "hostname" {
  description = "Public hostname for the API. e.g. `staging-api.meandr.com`, `api.meandr.com`. ALB listener rule + R53 record both use this."
  type        = string
}

variable "dns_zone_name" {
  description = "Public Route 53 hosted zone name (must exist in the Shared account). Used for ACM cert validation + the public A record."
  type        = string
  default     = "meandr.com"
}

variable "cert_domain" {
  description = "Cert primary domain. Default wildcard covers `*.meandr.com`."
  type        = string
  default     = "*.meandr.com"
}

variable "cert_subject_alternative_names" {
  description = "Extra SANs on the cert. Includes apex by default."
  type        = list(string)
  default     = ["meandr.com"]
}

# --- Image --------------------------------------------------------------

variable "ecr_registry" {
  description = "ECR registry URL. Default = Shared account eu-central-1; cross-region replication covers us-east-1."
  type        = string
  default     = "303529433558.dkr.ecr.eu-central-1.amazonaws.com"
}

variable "image_repository" {
  description = "ECR repo name. Same across all envs."
  type        = string
  default     = "meandr-api"
}

variable "image_tag" {
  description = "Mutable image tag. `develop` for staging, `main` for production. CI pushes new SHAs under this tag; force-new-deployment re-pulls."
  type        = string
}

# --- RDS Postgres -------------------------------------------------------

variable "db_instance_class" {
  description = "RDS instance class. Default staging-sized."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage_gb" {
  description = "Initial RDS storage."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage_gb" {
  description = "Upper bound for RDS storage autoscaling."
  type        = number
  default     = 100
}

variable "db_multi_az" {
  description = "RDS Multi-AZ. Off for staging."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "RDS backup retention. Bump for production."
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "Block accidental destroy. False for staging, true for production."
  type        = bool
  default     = false
}

# --- API Redis (ActionCable + other API-owned persistent state) ---------

variable "api_redis_node_type" {
  description = "ElastiCache node type for the API's own Redis (ActionCable pub/sub, future API-owned persistent state). Single-node, no replication; sized small. cache.t4g.micro is fine for staging."
  type        = string
  default     = "cache.t4g.micro"
}

# --- Valkey endpoints (created elsewhere; meandr-api just consumes) -----
#
# BE needs two Valkey planes:
#   - config-stream: BE writes config records + inbound events (one global
#     cluster). Always the writer (primary) endpoint — BE writes here.
#   - event-stream: BE consumes outbound streams (per-region cluster).
#     Also the writer endpoint — XREADGROUP is a write op.
#
# The config-stream cluster is single; event-stream is per-region. BE
# runs only in the primary region today, so cross-region event-stream
# writer endpoints come from each region's terraform_remote_state.
#
# Env-var wire names (MEANDR_REDIS_EGRESS_URL / MEANDR_REDIS_INGRESS_URLS)
# are kept stable on the Rails side; only the TF input names follow the
# new <plane>_<role>_endpoint convention.

variable "config_writer_endpoint" {
  description = "Writer (primary) endpoint of `meandr-config-stream`. AWS-internal hostname. BE writes config records and produces inbound events here. Maps onto MEANDR_REDIS_EGRESS_URL inside the container."
  type        = string
}

variable "event_writer_endpoints" {
  description = "Per-region writer (primary) endpoints of `meandr-event-stream`. AWS-internal hostnames. BE consumes outbound streams here (XREADGROUP needs the primary). Each entry becomes `rediss://<host>:6379` joined with commas into MEANDR_REDIS_INGRESS_URLS. Positionally paired with var.regions — entry N is the event-stream writer for region N."
  type        = list(string)
  default     = []
}

variable "config_stream_security_group_id" {
  description = "SG attached to the config-stream Valkey cluster. ECS task SGs need to be allowed to reach it (current pattern leans on VPC-CIDR ingress; kept here for future tightening)."
  type        = string
  default     = null
}

variable "regions" {
  description = "Region codes where the proxy fleet runs — every region with a `meandr-mcp` deployment that BE consumes streams from. Joined with commas into MEANDR_MCP_REGIONS. Positionally paired with var.event_writer_endpoints — entry N labels the writer endpoint at event_writer_endpoints[N]."
  type        = list(string)
}

# --- Per-service sizing -------------------------------------------------

variable "puma" {
  description = "Sizing + replica bounds for the Rails Puma service (long-running, HTTP-facing)."
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
    desired_count          = 1
    min_replicas           = 1
    max_replicas           = 4
    target_cpu_utilization = 70
  }
}

variable "jobs" {
  description = "Sizing + replica bounds for the Good Job worker service."
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
    desired_count          = 1
    min_replicas           = 1
    max_replicas           = 4
    target_cpu_utilization = 70
  }
}

variable "ingest" {
  description = "Sizing for the proxy-ingest service — long-running blocking reader on each region's event-stream Valkey. Fixed-replica (no autoscaling): blocking XREADGROUP holds one connection per region thread, so horizontal scaling means splitting `regions:` across processes, not adding more workers behind the same regions. Default 1 desired = 1 replica owns every region; bump only when a single process can't keep up with one of them."
  type = object({
    cpu           = number
    memory        = number
    desired_count = number
  })
  default = {
    cpu           = 256
    memory        = 512
    desired_count = 1
  }
}

variable "migrate" {
  description = "CPU/memory for the one-off migrate task. Bigger than runtime services — schema loads can be heavy."
  type = object({
    cpu    = number
    memory = number
  })
  default = {
    cpu    = 512
    memory = 1024
  }
}

# --- Logging ------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch log retention for all task families."
  type        = number
  default     = 30
}

# --- Tags ---------------------------------------------------------------

variable "extra_tags" {
  description = "Extra tags merged into every resource on top of the standard meandr tags."
  type        = map(string)
  default     = {}
}
