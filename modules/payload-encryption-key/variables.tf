variable "env" {
  description = "Environment name (development / staging / production). Drives the alias name and the description string."
  type        = string

  validation {
    condition     = contains(["development", "staging", "production"], var.env)
    error_message = "env must be development, staging, or production."
  }
}

variable "alias_name" {
  description = "KMS alias short name, prefixed `alias/` by AWS. Convention: `meandr-payload-<env>`. Aliases let callers (proxy GenerateDataKey/Decrypt, BE Decrypt-on-user-view) reference the key by a stable name across rotations of the underlying CMK material."
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
  description = "Multi-Region key. IMMUTABLE after key creation — set correctly at first apply. Production MUST be true (multi-region rollout planned); staging can stay false (single-region eu-central-1). When true, KMS lets you create replicas of this key in other regions; replicas decrypt anything the primary encrypted and vice versa, no cross-region API calls needed at Decrypt time."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags applied to the key + alias."
  type        = map(string)
  default     = {}
}
