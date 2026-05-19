variable "name" {
  description = "Logical name for the DB instance. Used as the AWS resource identifier and in Name tags. Keep short and purpose-driven (e.g. `meandr-api`)."
  type        = string
}

variable "engine_version" {
  description = "Postgres major.minor version. We standardize on PG 18 end-to-end (UUIDv7 support is the driver — see meandr-api savepoint 2026-05-09)."
  type        = string
  default     = "18.4"
}

variable "instance_class" {
  description = "RDS instance class. Staging baseline: `db.t4g.micro`. Production should be at least `db.t4g.medium` or `db.r7g.large` depending on load."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage_gb" {
  description = "Initial storage size in GB. gp3 is used (better baseline IOPS than gp2 for the same price). Storage autoscaling extends this up to `max_allocated_storage_gb`."
  type        = number
  default     = 20
}

variable "max_allocated_storage_gb" {
  description = "Upper bound for storage autoscaling. 0 disables autoscaling."
  type        = number
  default     = 100
}

variable "multi_az" {
  description = "Multi-AZ deployment. Doubles cost. Leave false for staging (single AZ VPC anyway); enable for production once workloads run."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Daily snapshot retention. 7 days for staging; consider 14–35 for production."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Block accidental destruction via AWS. Leave false for staging so we can tear down freely; flip true for production."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. True for staging (data is ephemeral); false for production."
  type        = bool
  default     = true
}

variable "db_name" {
  description = "Initial database to create. The meandr-api Rails app uses one logical DB per env (`meandr_production`, `meandr_staging`, …)."
  type        = string
}

variable "master_username" {
  description = "Master user for the DB. The Rails app does NOT use this — it's the admin account for migrations and break-glass. App accesses go via per-service users created out-of-band."
  type        = string
  default     = "meandr_admin"
}

variable "vpc_id" {
  description = "VPC to place the DB into. From the vpc module output."
  type        = string
}

variable "vpc_cidr_block" {
  description = "VPC CIDR. Used as the ingress source — anything in this VPC can reach the DB. Tighter source SGs can be added later if we want strict per-service ACLs."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs the DB subnet group spans. Need at least 2 in different AZs even for single-AZ deployments (AWS requirement)."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "RDS requires a DB subnet group with subnets in at least 2 AZs, even for single-AZ deployments. For staging single-AZ VPCs, see the dual-subnet workaround in the caller comment."
  }
}

variable "internal_dns_zone_id" {
  description = "Route 53 private hosted zone ID. A CNAME `pg.<env>.meandr.local` → RDS endpoint is created here so connection strings stay stable across instance recreations."
  type        = string
}

variable "internal_dns_zone_name" {
  description = "Internal DNS zone name (e.g. `staging.meandr.local`). The CNAME record name will be `pg.<zone_name>`."
  type        = string
}

variable "secret_name" {
  description = "Secrets Manager path where the master password is stored. Convention: `meandr/db/<env>/master`. The proxy/api retrieves this at boot."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}
