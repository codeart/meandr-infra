variable "name" {
  description = "Human label for the pair, e.g. `us-east-1 to eu-central-1`. Tags only."
  type        = string
}

variable "vpc_id" {
  description = "This side's VPC."
  type        = string
}

variable "cidr_block" {
  description = "This side's CIDR, routed from the peer."
  type        = string
}

variable "route_table_id" {
  description = "This side's shared private route table, if it has one. Private, because the fleets and tasks that need the link live there. A compute VPC has per-AZ tables only."
  type        = string
  default     = null
}

variable "peer_vpc_id" {
  type = string
}

variable "peer_region" {
  type = string
}

variable "peer_cidr_block" {
  type = string
}

variable "peer_route_table_id" {
  description = "The peer's shared private route table, if it has one. Edited through the aws.peer provider, so adding a region touches no resource the peer's state owns."
  type        = string
  default     = null
}

variable "az_route_table_ids" {
  description = <<-EOT
    This side's PER-AZ private tables, KEYED BY AZ. Separate from
    route_table_id so the shared table's live route is never recreated —
    see the note above the resources.

    A map, not a list, and the key has to be the AZ: these ids do not exist
    until apply, and `for_each` over unknown values cannot determine its
    keys. Keyed by AZ the keys are static and only the values are deferred,
    which is the shape Terraform asks for.
  EOT
  type        = map(string)
  default     = {}
}


variable "tags" {
  type    = map(string)
  default = {}
}
