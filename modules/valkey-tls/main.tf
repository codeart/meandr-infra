# The internal CA and node keypair for a Valkey fleet, plus the two
# secrets that distribute them.
#
# Separate from valkey-node because it is created ONCE per environment and
# consumed by every node, in every region. Folding it into the node module
# would generate a fresh CA per instance, which is not a CA.
#
# ONE keypair for the whole fleet rather than one per node. Every node
# holds the same AUTH and the same data, so per-node keys would add
# rotation work without narrowing any blast radius. The cert provides
# CONFIDENTIALITY on the wire; identity is established by the security
# group and AUTH.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.24" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

locals {
  # 20 years. Long-lived leaf certs are normally poor practice; the trade
  # here is deliberate and narrow — this CA never leaves our infrastructure,
  # signs exactly one keypair, and secures a service that is already behind
  # a security group and an AUTH token. Rotation machinery we would never
  # exercise is worth less than the certainty of never touching it.
  #
  # Not 100 years: some TLS stacks reject implausible validity, and the
  # difference between 20 and 100 is not a difference anyone lives to see.
  validity_hours = 20 * 365 * 24

  subject = {
    organization = "Meandr, Inc."
    street       = ["169 Madison Ave, STE 66267"]
    locality     = "New York"
    province     = "NY"
    postal_code  = "10016"
    country      = "US"
  }
}

# --- CA -----------------------------------------------------------------

resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem

  subject {
    common_name         = "Meandr Internal Valkey CA (${var.env})"
    organization        = local.subject.organization
    organizational_unit = "Infrastructure"
    street_address      = local.subject.street
    locality            = local.subject.locality
    province            = local.subject.province
    postal_code         = local.subject.postal_code
    country             = local.subject.country
  }

  is_ca_certificate     = true
  validity_period_hours = local.validity_hours

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

# --- Node keypair -------------------------------------------------------

resource "tls_private_key" "node" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "node" {
  private_key_pem = tls_private_key.node.private_key_pem

  subject {
    common_name    = "valkey.${var.dns_zone_name}"
    organization   = local.subject.organization
    street_address = local.subject.street
    locality       = local.subject.locality
    province       = local.subject.province
    postal_code    = local.subject.postal_code
    country        = local.subject.country
  }

  # ONE leaf for the whole environment, two tiers of wildcard.
  #
  #   *.<zone>          flat names — the RDS/ElastiCache CNAMEs already there
  #   *.<family>.<zone> a nested service family, one entry each
  #
  # Both are needed because a wildcard matches exactly one label: `*.<zone>`
  # covers `valkey.<zone>` and not `config-a.valkey.<zone>`. Within a
  # family the wildcard is open-ended, so every valkey fleet and node —
  # config-a, config-master, events-a, config-euw1 — is covered forever
  # without touching this cert.
  #
  # No IP SANs, deliberately — addresses are assigned at launch and cannot
  # be known here. That is why Sentinel runs with resolve-hostnames.
  dns_names = concat(
    [var.dns_zone_name, "*.${var.dns_zone_name}"],
    [for s in var.service_subdomains : "*.${s}.${var.dns_zone_name}"],
  )
}

resource "tls_locally_signed_cert" "node" {
  cert_request_pem   = tls_cert_request.node.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = local.validity_hours

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
    # Replication makes a node a CLIENT of its master, so the same cert has
    # to serve both directions.
    "client_auth",
  ]
}

# --- Distribution -------------------------------------------------------
#
# TWO secrets, and the split is the point: the CA cert is public, the node
# key is not. Proxy and BE need only the former, and giving them a secret
# containing the private key would hand every task the ability to
# impersonate the fleet.

# --- Client keypair -----------------------------------------------------
#
# Separate from the node keypair so a proxy task never holds the key the
# fleet serves with. Client auth only — it cannot impersonate a node.

resource "tls_private_key" "client" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "client" {
  private_key_pem = tls_private_key.client.private_key_pem

  subject {
    common_name    = "valkey-client.${var.dns_zone_name}"
    organization   = local.subject.organization
    street_address = local.subject.street
    locality       = local.subject.locality
    province       = local.subject.province
    postal_code    = local.subject.postal_code
    country        = local.subject.country
  }
}

resource "tls_locally_signed_cert" "client" {
  cert_request_pem   = tls_cert_request.client.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = local.validity_hours

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "client_auth",
  ]
}

resource "aws_secretsmanager_secret" "client" {
  name        = "meandr/valkey/${var.env}/client"
  description = "Valkey client TLS material (ca_crt, client_crt, client_key). Read by proxy and BE."

  dynamic "replica" {
    for_each = var.replica_regions
    content {
      region = replica.value
    }
  }

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "client" {
  secret_id = aws_secretsmanager_secret.client.id
  secret_string = jsonencode({
    ca_crt     = tls_self_signed_cert.ca.cert_pem
    client_crt = tls_locally_signed_cert.client.cert_pem
    client_key = tls_private_key.client.private_key_pem
  })
}

resource "aws_secretsmanager_secret" "node" {
  name        = "meandr/valkey/${var.env}/node"
  description = "Valkey node TLS material (ca_crt, node_crt, node_key). Read by Valkey instances only."

  dynamic "replica" {
    for_each = var.replica_regions
    content {
      region = replica.value
    }
  }

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "node" {
  secret_id = aws_secretsmanager_secret.node.id
  secret_string = jsonencode({
    ca_crt   = tls_self_signed_cert.ca.cert_pem
    node_crt = tls_locally_signed_cert.node.cert_pem
    node_key = tls_private_key.node.private_key_pem
  })
}

resource "aws_secretsmanager_secret" "ca" {
  name        = "meandr/valkey/${var.env}/ca"
  description = "Valkey CA certificate only. Read by proxy and BE so they can verify the fleet; carries no private key."

  dynamic "replica" {
    for_each = var.replica_regions
    content {
      region = replica.value
    }
  }

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "ca" {
  secret_id     = aws_secretsmanager_secret.ca.id
  secret_string = tls_self_signed_cert.ca.cert_pem
}
