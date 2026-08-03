variable "name" {
  description = "Bucket name. S3's namespace is GLOBAL — unique across every AWS account on earth, not per-account — so the env must appear in the name even though each env is its own account. Convention: `meandr-mcp-logs-<env>` for the metadata archive (one per env) and `meandr-mcp-archive-<region>-<env>` for bodies (one per region)."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK for SSE-KMS default encryption. Reuse the per-env payload CMK (`alias/meandr-payload-<env>`) rather than minting a third key: per-tenant CMKs are an Enterprise/BYOK question (capture_and_archive.md §10), and each key is ~$1/month plus request charges."
  type        = string
}

variable "retention_classes" {
  description = <<-EOT
    Map of retention CLASS -> days, one lifecycle rule each. An object opts in
    by carrying `retention=<class>` as an object tag at PUT, set from the host
    record's plan-derived value (redis_schema.md §6.1.1).

    `none` and `inf` are deliberately absent: `none` writes no object at all,
    and `inf` is tagged like the rest but matches no rule — the absence of a
    rule IS the permanence.

    ORDER MATTERS when adding a class: the rule must exist here BEFORE BE may
    write the enum value, or objects written in between carry a tag nothing
    matches and become `inf` by accident, indistinguishable afterwards from
    ones that meant it.

    Months are 30 days, years are 365; nothing is calendar-aware. S3 sweeps
    asynchronously, so a class is a floor rather than an exact date.
  EOT
  type        = map(number)
  default = {
    "1d"  = 1
    "1m"  = 30
    "3m"  = 90
    "1y"  = 365
    "2y"  = 730
    "5y"  = 1825
    "10y" = 3650
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
