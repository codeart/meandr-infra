# Global Accelerator: one anycast front door for every region's proxy.
#
# Two static IPs announced from AWS edge locations worldwide. A client's
# packets enter the AWS backbone at the nearest edge and cross it to a
# healthy endpoint, instead of traversing the public internet end to end.
#
# Chosen over latency-based Route 53 for one reason that matters to MCP:
# agents hold LONG-LIVED streams and do not re-resolve DNS. A Route 53
# failover moves new lookups and leaves existing connections pointed at a
# dead region until the client happens to reconnect. GA fails over inside
# the network, in seconds, with the address unchanged.
#
# It is not free: ~$18/month per accelerator plus a per-GB premium ON TOP
# of normal egress. That premium applies to proxy traffic, which is the
# thing that scales — revisit if it outgrows what the failover is worth.
#
# THE CONTROL PLANE IS us-west-2 ONLY. Accelerators, listeners and even
# endpoint groups for other regions are all created through that endpoint,
# which is why this module takes an aliased provider rather than inheriting
# the caller's.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.24"
      configuration_aliases = [aws.usw2, aws.dns]
    }
  }
}

resource "aws_globalaccelerator_accelerator" "main" {
  provider = aws.usw2

  name            = "meandr-${var.env}"
  ip_address_type = "IPV4"
  enabled         = true

  attributes {
    flow_logs_enabled = false
  }

  tags = var.tags
}

# One TCP listener covering both proxy ports.
#
# Affinity NONE: routing to an endpoint group is by proximity and health, so
# a client's connections still land in one region under normal conditions.
# SOURCE_IP additionally pins every client behind one NAT to a single
# endpoint, which is the wrong trade for a shared-egress caller.
#
# What that costs at a region boundary or during a health flap: the proxy's
# upstream session is region-local, and clientguard counts against the
# events Valkey, which does not replicate. See docs/cross_node_delivery.md.
#
# TCP, not TLS: the proxy terminates TLS itself and owns SNI-based cert
# selection (cert_store.md §2). Terminating at the accelerator would take
# that away and require the wildcard to live in ACM instead.
resource "aws_globalaccelerator_listener" "main" {
  provider = aws.usw2

  accelerator_arn = aws_globalaccelerator_accelerator.main.id
  client_affinity = "NONE"
  protocol        = "TCP"

  port_range {
    from_port = 80
    to_port   = 80
  }

  port_range {
    from_port = 443
    to_port   = 443
  }
}

# The tenant wildcard, pointed at the accelerator rather than at any one
# region's NLB.
#
# This record USED to be created by the meandr-mcp module, per region —
# which worked exactly as long as there was one region, and would have had
# two state files fighting over one name as soon as there were two. Owning
# it here is what makes an edge able to stand up an NLB without claiming
# DNS.
#
# GA's hosted zone id is the same global constant everywhere (Z2BJ6XQ5FK7U4H).
resource "aws_route53_record" "wildcard" {
  provider = aws.dns

  zone_id = data.aws_route53_zone.public.zone_id
  name    = "*.${var.dns_zone_name}"
  type    = "A"

  alias {
    name                   = aws_globalaccelerator_accelerator.main.dns_name
    zone_id                = aws_globalaccelerator_accelerator.main.hosted_zone_id
    evaluate_target_health = true
  }
}

data "aws_route53_zone" "public" {
  provider = aws.dns

  name         = var.dns_zone_name
  private_zone = false
}
