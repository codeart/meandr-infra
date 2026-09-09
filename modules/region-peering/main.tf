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
# route — dropping the cross-region path for the length of an apply, on
# the link that carries config Valkey's replication.
#
# Pass EVERY per-AZ table, not the ones that look like they need it. A
# table missing this route has no path to the peer at all: an ECS task in
# that zone cannot reach the other region's proxy tasks over the mesh, and
# it fails as a timeout with nothing logged.
#
# Reasoning from what a zone holds today is how this was got wrong once
# already — an arbiter zone was left out on 2026-09-09, and the zone beside
# it, which runs tasks, was left out with it.
resource "aws_route" "to_peer_per_az" {
  for_each = toset(var.az_route_table_ids)

  route_table_id            = each.value
  destination_cidr_block    = var.peer_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

resource "aws_route" "from_peer_per_az" {
  provider = aws.peer

  for_each = toset(var.peer_az_route_table_ids)

  route_table_id            = each.value
  destination_cidr_block    = var.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id
}