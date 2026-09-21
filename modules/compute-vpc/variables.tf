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

# Short region code (euc1, use1) — the naming convention's region part:
# <role>-<scope>-<code><az>, e.g. nat-hosted-euc1a (the valkey pattern).
variable "region_code" {
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

variable "alarm_topic_arns" {
  description = "SNS topics for the module's alarms (NAT health, events DLQ)."
  type        = list(string)
  default     = []
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

variable "agent_image" {
  description = "meandr-agent image URI (multi-arch manifest). Empty = no agent daemon yet."
  type        = string
  default     = ""
}

# The env-wide agent token, one per environment: the PRIMARY region's
# stack creates the SM secret (meandr/hosted/<env>/agent-token, the
# redis_auth pattern) and replicates to compute regions; each region
# passes its LOCAL copy's ARN here. BE validates against the primary.
variable "agent_token_secret_arn" {
  type    = string
  default = ""
}

variable "agent_report_url" {
  description = "BE ingest endpoint the agent POSTs to (contracts/hosted_agent_report.md)."
  type        = string
  default     = ""
}

variable "api_base_url" {
  description = "BE API origin (https://…, no trailing slash); event destinations POST under /api/hosted/v1/events/ (contracts/hosted_platform_events.md)."
  type        = string
}

# Env-wide like the agent token but a separate trust domain (AWS, not the
# fleet); minted by the primary-region caller, value — not ARN — because
# the EventBridge connection embeds it as a header.
variable "events_token" {
  type      = string
  sensitive = true
}
