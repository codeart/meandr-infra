variable "env" {
  description = "Environment slug (dev/stg/prd). Namespaces the secrets and appears in the CA's common name, so a cert from the wrong environment is obvious rather than merely wrong."
  type        = string
}

variable "dns_zone_name" {
  description = "Private zone this environment's internal names live under. Every SAN derives from it."
  type        = string
}

variable "service_subdomains" {
  description = <<-EOT
    Service-family subdomains that get their own wildcard SAN, e.g.
    `valkey` → `*.valkey.<zone>`.

    A wildcard matches exactly ONE label, so `*.<zone>` covers a flat name
    like `db.<zone>` but NOT a nested one like `config-a.valkey.<zone>`.
    Every family that nests therefore needs its own entry. `*.*.<zone>` is
    not a thing — X.509 wildcards are leftmost-label only.

    Adding a family here regenerates the cert, which means redistributing
    it to everything already holding one. Adding a FLEET inside an existing
    family costs nothing, which is why fleets are labels and families are
    subdomains.
  EOT
  type        = list(string)
  default     = ["valkey"]
}

variable "replica_regions" {
  description = <<-EOT
    Regions to replicate both secrets into.

    Secrets Manager is regional, and an edge node cannot read a secret
    that only exists in the API region. Replicas are read-only copies,
    billed per region — the alternative is copying by hand, which drifts.
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
