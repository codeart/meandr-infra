variable "domain_name" {
  description = "Primary domain for the cert. Wildcards allowed (e.g. `*.meandr.com`). The cert is created in whichever account the default `aws` provider points to; DNS validation records go to the account the `aws.dns` provider points to."
  type        = string
}

variable "subject_alternative_names" {
  description = "Additional names on the cert. Useful to cover apex + wildcard in one cert (e.g. `[\"meandr.com\"]` alongside `*.meandr.com`)."
  type        = list(string)
  default     = []
}

variable "dns_zone_name" {
  description = "Route 53 zone name to validate against (e.g. `meandr.com`). Must be the public hosted zone for `domain_name`'s parent."
  type        = string
}

variable "tags" {
  description = "Common tags applied to the cert."
  type        = map(string)
  default     = {}
}
