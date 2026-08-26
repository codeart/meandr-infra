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
  description = "Internal zone name (e.g. `staging.meandr.internal`). Suffix for CNAMEs."
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

variable "extra_hostnames" {
  description = <<-EOT
    Additional public hostnames this API front answers on, beyond `hostname`.
    Each gets a Route 53 alias to the same ALB and joins the listener rule's
    host_header condition.

    Today: the OAuth 2.1 issuer host — `mcp.meandr.com` (prod),
    `staging-mcp.meandr.com` (staging) — which MCP clients reach after
    reading the proxy's RFC 9728 metadata. It lives HERE rather than in the
    MCP zone because *.meandr.io is the tenant wildcard, and an issuer there
    would need a permanently reserved slug to stop a tenant from serving
    their own metadata at it.

    Must stay inside the cert's coverage (*.meandr.com by default), or the
    TLS handshake fails before any of this matters.
  EOT
  type        = list(string)
  default     = []
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

# --- Redis AUTH (shared token across all three fleets) -----------------
#
# One token per env. Network isolation and mTLS are the primary controls;
# AUTH is defence in depth. Only the ARN travels — nodes and tasks both
# read the value from Secrets Manager, so no plaintext passes through
# Terraform.

variable "redis_auth_secret_arn" {
  description = "ARN of the SM secret holding the same AUTH token. Wired into task defs as a secret named MEANDR_REDIS_PASSWORD so Rails reads it at boot. Empty disables the secret wiring; must be set when redis_auth_token is set."
  type        = string
  default     = ""
}

# --- Credential store (DynamoDB + KMS envelope) ------------------------
#
# `cred_store_enabled` gates the IAM policy count separately from the
# ARN value because `count` needs a known-at-plan-time bool — same
# pattern as redis_auth_enabled above.

variable "cred_store_enabled" {
  description = "Explicit on/off gate for cred-store wiring on the BE side. Set true alongside the table_arn + key_arn + path_prefix inputs; false leaves the env vars empty and the IAM policy absent."
  type        = bool
  default     = false
}

#
# BE side of the cred-store architecture. Rails writes AES-256-GCM blobs
# to the cred Dynamo table and manages the dated SM secrets that hold
# KMS-wrapped data keys. See docs/credential_store.md for the full
# Ruby↔Go wire contract.
#
# Caller creates the table (modules/dynamodb-creds-table) + the KMS CMK
# (modules/cred-encryption-key) at the region level and passes both
# ARNs here. The proxy gets the same table ARN + a narrower IAM scope
# (read-only on the table; Decrypt-only on the CMK).

variable "creds_table_name" {
  description = "DynamoDB cred-store table name. Goes into MEANDR_CRED_TABLE_NAME for Rails. Empty disables cred-store wiring on the BE side."
  type        = string
  default     = ""
}

variable "creds_table_arn" {
  description = "DynamoDB cred-store table ARN. Used to scope the task role's DynamoDB R/W policy to this specific table."
  type        = string
  default     = ""
}

variable "cred_encryption_key_arn" {
  description = "KMS CMK ARN for the AEAD envelope key. BE calls KMS.GenerateDataKey + KMS.Decrypt against it; IAM is scoped to this single ARN."
  type        = string
  default     = ""
}

variable "cred_encryption_key_alias" {
  description = "KMS alias for the CMK (with `alias/` prefix, e.g. `alias/meandr-cred-staging`). Goes into MEANDR_CRED_KMS_KEY_ALIAS. BE calls KMS.Encrypt(KeyId=alias) on cred writes; the alias survives CMK rotation if we ever swap the underlying key."
  type        = string
  default     = ""
}

variable "acme_dns_role_arn" {
  description = "ARN of the ACME DNS role in the Shared account (`meandr-acme-dns-<env>`, output by shared/acme.tf). Goes into MEANDR_ACME_DNS_ROLE_ARN and is the sole Resource of the task role's sts:AssumeRole grant. Empty disables both — Meandr::Acme reads it lazily, so only a real cert order notices."
  type        = string
  default     = ""

  validation {
    condition     = var.acme_dns_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/", var.acme_dns_role_arn))
    error_message = "acme_dns_role_arn must be an IAM role ARN, or empty."
  }
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
# How BE reaches the three Valkey fleets. Sentinel only — a plain URL
# cannot carry a client certificate, and the fleets refuse a connection
# without one. See docs/valkey_fleets.md §5.

variable "config_sentinel_addrs" {
  description = "Sentinel endpoints for the config fleet, `host:26379`. Singular — one config master globally, which is the point of that fleet."
  type        = list(string)
}

variable "config_sentinel_master" {
  description = "Sentinel master name for the config fleet — the fleet name. Unique within a Sentinel set, not globally."
  type        = string
}

variable "event_sentinel_groups" {
  description = <<-EOT
    Per-region Sentinel groups for the event fleets. Each entry is one
    region's comma-separated `host:26379` list; entries are joined with
    `;` into MEANDR_REDIS_INGRESS_SENTINELS.

    Positionally paired with var.regions — entry N is region N's group,
    enforced by input_pairing_guard.

    BE reads EVERY region's group, unlike the proxy which only ever needs
    its own: BE consumes every region's event stream.
  EOT
  type        = list(string)
}

variable "event_sentinel_master" {
  description = "Sentinel master name for the event fleets. The same in every region — Sentinel names only have to be unique within a set."
  type        = string
}

variable "api_sentinel_addrs" {
  description = "Sentinel endpoints for the api fleet (ActionCable pub/sub + presence)."
  type        = list(string)
}

variable "api_sentinel_master" {
  description = "Sentinel master name for the api fleet."
  type        = string
}

variable "valkey_client_secret_arn" {
  description = <<-EOT
    Secrets Manager ARN holding `{ca_crt, client_crt, client_key}` — the
    CLIENT half of the self-hosted Valkey PKI.

    Required to reach those fleets at all: nodes run `tls-auth-clients
    yes` and refuse a connection without a certificate. Written into
    every task as FILES, since the Rails image has a shell and a file
    keeps the key out of the process environment.

    Empty leaves BE on ElastiCache.
  EOT
  type        = string
  default     = ""
}


variable "regions" {
  description = "Region codes where the proxy fleet runs — every region with a `meandr-mcp` deployment that BE consumes streams from. Joined with commas into MEANDR_MCP_REGIONS. Positionally paired with var.event_sentinel_groups — entry N labels the group at event_sentinel_groups[N]."
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
    concurrency            = number
    threads                = number
  })
  default = {
    cpu                    = 256
    memory                 = 512
    desired_count          = 1
    min_replicas           = 1
    max_replicas           = 4
    target_cpu_utilization = 70
    concurrency            = 2
    threads                = 5
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

# --- Payload capture / archive ------------------------------------------
#
# `capture_enabled` gates the IAM policy count separately from the ARNs,
# for the same plan-time reason as cred_store_enabled.

variable "capture_enabled" {
  description = "Explicit on/off gate for BE's S3 grants. Set true alongside the three ARNs below."
  type        = bool
  default     = false
}

variable "archive_bucket_arn" {
  description = "Archive bucket ARN (calls + actions Parquet). BE WRITES this one — it is the daily archiver's target and the only bucket Athena scans."
  type        = string
  default     = ""
}

variable "payloads_bucket_arn" {
  description = "Payloads bucket ARN (request/response bodies). BE gets READ + RETAG here, never write: the proxy is the only writer of bodies. Read serves the dashboard's 'show me the request'; retag is the cancellation flow, which moves an account's objects from `inf` to `1d` and lets the bucket's own lifecycle do the deleting (redis_schema.md §6.1.1)."
  type        = string
  default     = ""
}

variable "payload_encryption_key_arn" {
  description = "BUCKET-at-rest CMK ARN. Both buckets are SSE-KMS, so the caller needs GenerateDataKey to write and Decrypt to read."
  type        = string
  default     = ""
}

variable "action_key_enabled" {
  description = "Explicit on/off gate for the action-form key grant. Separate from envelope_encryption_key_arn for the same reason redis_auth_enabled is separate from its secret ARN: `count` needs a value known at PLAN time, and the ARN of a not-yet-created KMS key is not one."
  type        = bool
  default     = false
}

variable "envelope_encryption_key_arn" {
  description = <<-EOT
    APPLICATION envelope CMK ARN — payloadcrypt. BE unwraps elicitation
    form answers with it, wrapped by whichever region's proxy handled the
    form, which is why it is multi-region while the bucket key is not.

    Granted alongside the bucket key. Envelopes record their own CMK, so
    ones wrapped by an older key keep decrypting as long as that key
    exists and is still granted.
  EOT
  type        = string
  default     = ""
}

variable "self_ips_parameter_arn" {
  description = "SSM parameter holding our public ingress addresses. Written by the account-level stack and read by the proxy too, so BE validation and the proxy's dial guard agree. Empty disables it."
  type        = string
  default     = ""
}
