variable "upstream_credentials" {
  description = "Create the pull-through cache rules. Set once the ecr-pullthroughcache/ secrets hold {\"username\",\"accessToken\"} and this region has them."
  type        = bool
  default     = false
}

variable "secrets_home" {
  description = "True in the one region that holds the ecr-pullthroughcache/ secrets; the others read its replicas."
  type        = bool
}

variable "replica_regions" {
  description = "Where the home region replicates the secrets."
  type        = list(string)
  default     = []
}

variable "buildkit_version" {
  description = "moby/buildkit tag the builds run, pulled through the cache."
  type        = string
  default     = "v0.34.0"
}

variable "log_retention_days" {
  description = "How long build output stays readable to BE."
  type        = number
  default     = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
