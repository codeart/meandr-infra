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
  description = "This side's private route table. Private, because the fleets and tasks that need the link live there."
  type        = string
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
  description = "The peer's private route table. Edited through the aws.peer provider, so adding a region touches no resource the peer's state owns."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
