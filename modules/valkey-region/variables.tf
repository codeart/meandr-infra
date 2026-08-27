variable "fleets" {
  description = <<-EOT
    The fleets this region runs, keyed by fleet name. Every value is
    optional — an empty object gets the primary-region defaults.

    This is where a region's role shows up:

      config = { promotable = false, create_master_record = false }  # edge
      events = { master_record_label = "events-master-use1" }
      api    = { maxmemory_policy = "allkeys-lru" }                  # primary only

    Also sizes the capacity reservations, so adding a fleet cannot leave a
    node without a slot.
  EOT

  # Defaults live here, so callers state only what differs and the module
  # never sees a null.
  type = map(object({
    promotable            = optional(bool, true)
    create_master_record  = optional(bool, true)
    master_record_label   = optional(string, "")
    maxmemory_policy      = optional(string, "noeviction")
    backup_bucket_enabled = optional(bool, true)
  }))
}

variable "env" {
  type = string
}

variable "region" {
  description = "Full AWS region — names the artifacts bucket and the reservation AZs."
  type        = string
}

variable "region_code" {
  description = "Short code used in node names (`euc1`, `use1`). Region-qualified because the DNS zone is shared."
  type        = string
}

variable "valkey_version" {
  type = string
}

variable "valkey_source_path" {
  description = "Path to the vendored tarball. A version with no tarball fails at plan, which is the point."
  type        = string
}

variable "backup_bucket" {
  description = "Name for this region's RDB backup bucket. A literal rather than a computed id: the node module gates backup IAM on a count, which must be known at plan time."
  type        = string
}

variable "backup_retention_days" {
  type    = number
  default = 30
}

variable "instance_type" {
  type    = string
  default = "t4g.nano"
}

variable "sentinel_quorum" {
  description = "Fleet-wide constant. Does not scale with region count — see valkey_fleets.md §6."
  type        = number
  default     = 2
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
  description = "Exactly three private subnets, positionally [a, b, c]."
  type        = list(string)
}

variable "client_cidrs" {
  description = "CIDRs allowed on 6379 and 26379, including peer regions — security-group references do not cross regions."
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
