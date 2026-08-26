variable "env" {
  description = "Environment name (development / staging / production). Names the accelerator."
  type        = string
}

variable "dns_zone_name" {
  description = "Public apex the proxy serves — `meandr.live` for staging, `meandr.io` for production. The `*.<apex>` record is created here and points at the accelerator, so no region may create it."
  type        = string
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
