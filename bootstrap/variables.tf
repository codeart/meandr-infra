variable "region" {
  description = "Region where bootstrap resources live. State buckets are regional but their contents address any region's resources."
  type        = string
  default     = "eu-central-1"
}

variable "state_bucket_name" {
  description = "S3 bucket name for Terraform state. Must be globally unique."
  type        = string
  default     = "meandr-tfstate-shared"
}

variable "log_bucket_name" {
  description = "S3 bucket name for state-bucket access logs."
  type        = string
  default     = "meandr-tfstate-shared-logs"
}

variable "lock_table_name" {
  description = "DynamoDB table for Terraform state locks (single table, all envs share)."
  type        = string
  default     = "meandr-tfstate-locks"
}

variable "kms_alias" {
  description = "Alias for the KMS key encrypting state at rest."
  type        = string
  default     = "alias/meandr-tfstate"
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default = {
    "meandr:env"        = "shared"
    "meandr:component"  = "tfstate-backend"
    "meandr:managed-by" = "terraform-bootstrap"
    "meandr:owner"      = "infra"
  }
}
