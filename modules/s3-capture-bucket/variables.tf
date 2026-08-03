variable "name" {
  description = "Bucket name. S3's namespace is GLOBAL — unique across every AWS account on earth, not per-account — so the env must appear in the name even though each env is its own account. Convention: `meandr-mcp-logs-<env>` for the metadata archive (one per env) and `meandr-mcp-archive-<region>-<env>` for bodies (one per region)."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK for SSE-KMS default encryption. Reuse the per-env payload CMK (`alias/meandr-payload-<env>`) rather than minting a third key: per-tenant CMKs are an Enterprise/BYOK question (capture_and_archive.md §10), and each key is ~$1/month plus request charges."
  type        = string
}

variable "retention_classes" {
  description = "Map of retention tag value -> days, one lifecycle rule each. An object opts in by carrying `retention=<key>` as an object tag at PUT, set from the tenant's plan. Keep this small: a rule per distinct value, against a 1,000-rules-per-bucket cap. Values are design intent until ratified into billing_pricing_matrix.md §3."
  type        = map(number)
  default = {
    "30"  = 30
    "90"  = 90
    "365" = 365
  }
}

variable "abort_incomplete_days" {
  description = "Days before an incomplete multipart upload is aborted. Abandoned parts are invisible in listings and billed forever, and this design expects abandonment (drain timeouts, SIGKILL, incidents). 1 is the doc's figure and there is no reason to wait longer — a segment that has not completed within a day is never completing."
  type        = number
  default     = 1
}

variable "tags" {
  description = "Tags applied to the bucket."
  type        = map(string)
  default     = {}
}
