variable "fleet" {
  description = "Fleet name — `config`, `events` or `api`. Also the Sentinel master name, unique within a Sentinel set rather than globally."
  type        = string
}

variable "region_code" {
  description = "Short region code used in node names (`euc1`, `use1`), producing `<fleet>-<code><az>`. Region-qualified because the DNS zone is shared: an unqualified name would exist in every region and resolve locally."
  type        = string
}

variable "promotable" {
  description = <<-EOT
    Whether Sentinel may promote these nodes to master.

    FALSE for a fleet whose master lives in another region — it emits
    `replica-priority 0`, making them structurally ineligible rather than
    merely unlikely. Defaults TRUE, so the safe edge value is the
    non-default one.
  EOT
  type        = bool
  default     = true
}

variable "create_master_record" {
  description = "Whether this region bootstraps the fleet's master CNAME. FALSE where the master is global and another region owns the name — a second writer would point every reader at a node that cannot accept writes."
  type        = bool
  default     = true
}

variable "master_record_label" {
  description = "Override for the master record name. Region-qualify it for per-region fleets (`events-master-use1`); leave empty for a fleet with one master environment-wide."
  type        = string
  default     = ""
}

variable "sentinel_quorum" {
  description = "Sentinels that must agree the master is down. Fleet-wide constant — nodes given different values disagree about what agreement means. Does not scale with region count; see valkey_fleets.md §6."
  type        = number
  default     = 2
}

variable "instance_type" {
  description = "ARM64 instance type. Both data nodes must match: they swap roles on failover."
  type        = string
  default     = "t4g.nano"
}

variable "arbiter_instance_type" {
  description = "ARM64 instance type for the AZ-c arbiter, which runs valkey-sentinel and holds no data. Need not match the data nodes: it is never a promotion target."
  type        = string
  default     = "t4g.nano"
}

variable "maxmemory_percent" {
  description = "Percent of RAM for the dataset. t4g.nano is 512 MiB total and the OS takes ~250."
  type        = number
  default     = 50
}

variable "maxmemory_policy" {
  description = "`noeviction` for config and events — the eventbus refuses to start against anything else. `allkeys-lru` for api, where dropping the coldest key IS the behaviour."
  type        = string
  default     = "noeviction"
}

variable "valkey_version" {
  type = string
}

variable "valkey_source_bucket" {
  description = "Artifacts bucket holding the vendored source. Must be regional — nodes fetch through the S3 gateway endpoint."
  type        = string
}

variable "valkey_source_sha256" {
  type = string
}

variable "backup_bucket" {
  description = "RDB backup bucket, written by whichever node is currently the replica. Empty disables backups."
  type        = string
  default     = ""
}

variable "create_timeout" {
  description = "Launch timeout. Short values fail fast on InsufficientInstanceCapacity rather than letting the provider retry silently."
  type        = string
  default     = "2m"
}

variable "auth_secret_arn" {
  type = string
}

variable "tls_secret_arn" {
  description = "Node TLS material. One CA per environment, so an edge reads the replicated secret rather than minting its own."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Exactly three private subnets, positionally [a, b, c]. AZ-c takes the arbiter."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) == 3
    error_message = "subnet_ids must have exactly 3 entries, ordered [a, b, c]."
  }
}

variable "client_cidrs" {
  description = "CIDRs allowed on 6379 and 26379. Includes peer regions, because security-group references do not cross regions."
  type        = list(string)
}

variable "dns_zone_id" {
  type = string
}

variable "dns_zone_name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
