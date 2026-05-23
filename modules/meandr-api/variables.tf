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

# --- Valkey endpoints (created elsewhere; meandr-api just consumes) -----

variable "reader_internal_dns_name" {
  description = "Reader Valkey internal DNS name (e.g. `redis-reader.staging.meandr.local`). Caller creates the reader Valkey at the region level since both meandr-api and meandr-mcp use it."
  type        = string
}

variable "reader_security_group_id" {
  description = "SG attached to the reader Valkey. ECS task SGs need this referenced as a source... or simpler: ECS task SGs egress all to VPC CIDR, and reader SG ingresses from VPC CIDR (current pattern). Kept here for future tightening."
  type        = string
  default     = null
}

variable "writer_internal_dns_name" {
  description = "Writer Valkey internal DNS name. Optional — null when meandr-mcp is not yet deployed in this region. When set, REDIS_WRITER_URL env var is injected; when null, BE assumes no writer is available."
  type        = string
  default     = null
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
