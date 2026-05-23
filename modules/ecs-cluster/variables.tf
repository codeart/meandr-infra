variable "name" {
  description = "Cluster name. Reused as a prefix for the execution role and log group naming. Keep short (e.g. `meandr-api`)."
  type        = string
}

variable "log_retention_days" {
  description = "Days to retain CloudWatch logs from tasks in this cluster. Per `telemetry_architecture.md`, CW is for system signals only (no per-request app logs), so retention can be short."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}
