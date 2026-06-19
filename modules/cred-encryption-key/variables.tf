variable "env" {
  description = "Environment name (development / staging / production). Drives the alias name and the description string."
  type        = string

  validation {
    condition     = contains(["development", "staging", "production"], var.env)
    error_message = "env must be development, staging, or production."
  }
}

variable "alias_name" {
  description = "KMS alias short name, prefixed `alias/` by AWS. Convention: `meandr-cred-<env>`. Aliases let callers (BE Rails task that runs GenerateDataKey) reference the key by a stable name across rotations of the underlying CMK material."
  type        = string
}

variable "deletion_window_in_days" {
  description = "Window between `kms:ScheduleKeyDeletion` and actual destruction. AWS minimum is 7, max is 30. Default 30 for production-grade caution; lower in dev to match the throwaway nature."
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days must be between 7 and 30 (AWS limit)."
  }
}

variable "enable_key_rotation" {
  description = "Annual auto-rotation of the CMK material. Transparent to data keys — KMS keeps old key material around for decrypts of pre-rotation wrapped data keys. No app-side change required. Recommended on; only off for short-lived dev keys."
  type        = bool
  default     = true
}

variable "multi_region" {
  description = "Multi-Region key. When true, KMS lets you create replicas of this key in other regions; replicas decrypt anything the primary encrypted and vice versa. We don't need this for the BE-encrypts-once / proxy-decrypts-in-region pattern (the wrapped data key in SM is fetched once at boot by the proxy from any region — KMS Decrypt is then cross-region-capable on a single-region key too). Reserved for a future where we want per-region encryption write paths."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags applied to the key + alias."
  type        = map(string)
  default     = {}
}
