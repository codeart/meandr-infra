variable "cidr_block" {
  description = "VPC CIDR. Pick a /16 from RFC1918 that doesn't overlap any other env's VPC — required for future VPC peering safety. Staging: 10.10.0.0/16; production: 10.20.0.0/16."
  type        = string
}

variable "azs" {
  description = "List of AZs to span. Each gets one public + one private subnet. Use a single AZ for cost-sensitive envs (staging); multi-AZ for HA in production."
  type        = list(string)
}

variable "enable_nat" {
  description = "If true, create a NAT Gateway in the first public subnet so private subnets can reach the internet. Costs ~$32/month base + $0.045/GB processing. Set false for envs that have no running workloads (e.g. production before launch) — they cost $0/month for the VPC."
  type        = bool
  default     = true
}

variable "internal_dns_zone" {
  description = <<-EOT
    Name of the Route 53 private hosted zone created for this VPC. Used for
    internal service discovery — RDS, ElastiCache, Valkey and friends live
    here. Convention: `<env>.meandr.internal` (e.g. `staging.meandr.internal`).

    `.internal`, not `.local`. RFC 6762 reserves `.local` for mDNS, so a
    resolver is entitled to answer those from multicast rather than from
    us — and our own dev machines already wildcard `*.meandr.local` to
    127.0.0.1. ICANN reserved `.internal` in 2024 for exactly this: never
    delegated, guaranteed NXDOMAIN in public DNS, so a query that escapes
    fails instead of leaking a hostname or resolving to a stranger.
  EOT
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}
