variable "env" {
  description = "tst | stg | prd — tag/name scoping."
  type        = string
}

# The region's FIRST compute block from network_allocation.md §2 — e.g.
# \"10.11\" for eu-central-1, \"10.21\" for us-east-1. A region starts on
# x1: the primary CIDR is permanent (§3).
variable "block" {
  type = string

  validation {
    condition     = can(regex("^10\\.\\d{1,3}$", var.block))
    error_message = "block is the two-octet prefix from network_allocation.md §2, e.g. \"10.11\"."
  }
}

variable "azs" {
  description = "AZ letters, in placement-priority order. Three at launch (a-c); d-f join by adding the NEXT block, not by resizing (§3)."
  type        = list(string)
  default     = ["a", "b", "c"]
}

variable "region" {
  type = string
}

# The main VPC this compute VPC peers with — its ONLY peering (§5).
variable "main_vpc_id" {
  type = string
}

variable "main_vpc_cidr" {
  type = string
}

# Main-VPC route tables that need the return route to the fleet — the
# private tables carrying the proxy tasks.
variable "main_route_table_ids" {
  type = list(string)
}

variable "nat_instance_type" {
  type    = string
  default = "t4g.nano"
}

variable "nat_alarm_topic_arns" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "reserved_memory_mib" {
  description = "ECS_RESERVED_MEMORY: OS + agent headroom ECS never schedules into (hosted_nodes.md §7.2)."
  type        = number
  default     = 128
}
