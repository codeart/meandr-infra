variable "env" {
  description = "Environment name (development / staging / production). Appears in the key description; the alias is passed separately."
  type        = string

  validation {
    condition     = contains(["development", "staging", "production"], var.env)
    error_message = "env must be development, staging, or production."
  }
}

variable "purpose" {
  description = <<-EOT
    What this key protects, in one phrase. Goes into the CMK description
    together with the alias.

    This module serves more than one key — the bucket-at-rest key and the
    application envelope key are both built from it — so the description
    MUST be given, not hardcoded. It previously baked in
    `meandr-payload-<env>`, which meant the action key described itself as
    the payload key: two keys, one description, and the console gives you
    no other way to tell them apart.
  EOT
  type        = string
}

variable "alias_name" {
  description = "KMS alias short name, prefixed `alias/` by AWS. Aliases let callers reference the key by a stable name across rotations of the underlying CMK material."
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
  description = <<-EOT
    Multi-Region key. IMMUTABLE after creation — set it correctly on the
    first apply or the key must be replaced.

    Decide it by ONE question: does this key's ciphertext cross a region
    boundary? Credentials and application envelopes do — one blob is
    written in a region and opened in another — so those are `true`. The
    bucket-at-rest key does not: each region reads only what it wrote, and
    S3 replication decrypts with the source key and re-encrypts with the
    destination's, so it stays `false` in every environment.

    `false` is a GUARDRAIL, not a saving. A key that cannot be replicated
    cannot be quietly adopted for something that crosses regions — a
    misuse that works in one region and fails in the next.

    True only makes the key REPLICABLE; it names no region. Edges create
    their own `aws_kms_replica_key` pointing at this primary.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags applied to the key + alias."
  type        = map(string)
  default     = {}
}
