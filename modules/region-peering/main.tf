# Cross-region VPC peering, both ends declared from the requester's state.
#
# Resolving a name is not reaching it: the shared private zone gives the
# name, this gives the path, and security-group CIDR rules give admission
# (valkey_fleets.md §6). Peering is NOT transitive — three regions need a
# mesh or a Transit Gateway.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.24"
      configuration_aliases = [aws.peer]
    }
  }
}

resource "aws_vpc_peering_connection" "this" {
  vpc_id      = var.vpc_id
  peer_vpc_id = var.peer_vpc_id
  peer_region = var.peer_region

  # Cross-region cannot auto-accept; the accepter below does it.
  auto_accept = false

  tags = merge(var.tags, { Name = "${var.name} requester" })
}

resource "aws_vpc_peering_connection_accepter" "this" {
  provider = aws.peer

  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  auto_accept               = true

  tags = merge(var.tags, { Name = "${var.name} accepter" })
}

# Without this an instance resolving a peer hostname gets its PUBLIC
# address, which for private-only nodes is no address at all.
resource "aws_vpc_peering_connection_options" "requester" {
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  requester {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_vpc_peering_connection_options" "accepter" {
  provider = aws.peer

  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_route" "to_peer" {
  route_table_id            = var.route_table_id
  destination_cidr_block    = var.peer_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

# The peer's table is edited from HERE, and it is additive: the vpc module
# keeps routes as separate aws_route resources, so an apply over there
# cannot clobber this one.
resource "aws_route" "from_peer" {
  provider = aws.peer

  route_table_id            = var.peer_route_table_id
  destination_cidr_block    = var.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id
}

# The per-AZ tables, as SEPARATE resources rather than folding the shared
# table into a for_each. A for_each key would be the table id, which no
# `moved` block can name, so folding would destroy and recreate the live
# route, dropping the cross-region path for the length of an apply.
#
# EVERY per-AZ table, never a subset: a table without this route has no
# path to the peer and nothing reports it.
#
# Keyed by AZ, not by table id — these tables are created by the same
# apply, so their ids are unknown and a for_each over them cannot
# determine its keys.
resource "aws_route" "to_peer_per_az" {
  for_each = var.az_route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = var.peer_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

# Discovered by tag, not listed: a hardcoded list has to be re-copied every
# time the peer splits an AZ, and a missing entry leaves that zone with no
# path here and nothing to report it.
#
# Reads the peer's ACCOUNT, not its state file, so the two regions stay
# independent.
data "aws_route_tables" "peer_per_az" {
  provider = aws.peer

  vpc_id = var.peer_vpc_id

  filter {
    name   = "tag:meandr:scope"
    values = ["per-az-private"]
  }
}

resource "aws_route" "from_peer_per_az" {
  provider = aws.peer

  for_each = toset(data.aws_route_tables.peer_per_az.ids)

  route_table_id            = each.value
  destination_cidr_block    = var.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id
}