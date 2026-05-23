# ACM cert module — issues a public TLS cert with DNS validation.
#
# Two providers required:
#   - default `aws` provider: account/region where the cert lives (ALB will use it)
#   - aliased `aws.dns` provider: account where the Route 53 hosted zone for the
#     validated domain lives
#
# meandr partitions DNS to the Shared account and workloads to per-env accounts.
# That means ALB-bound certs in Staging/Production must validate against records
# in Shared. This module handles the cross-account dance.
#
# Cert renewal is automatic — ACM rotates ~60 days before expiry and the same
# validation CNAMEs keep it validated forever (no operator action needed).

# --- Cert request (in workload account) ----------------------------------

resource "aws_acm_certificate" "main" {
  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "cert ${var.dns_zone_name}"
  })
}

# --- DNS zone lookup (in Shared account) ---------------------------------

data "aws_route53_zone" "dns" {
  provider     = aws.dns
  name         = var.dns_zone_name
  private_zone = false
}

# --- Validation records (in Shared account) ------------------------------
#
# ACM returns a set of (record_name, record_type, record_value) tuples — one
# per name on the cert (domain_name + SANs). We materialize each as a Route 53
# record in the DNS account.

resource "aws_route53_record" "validation" {
  provider = aws.dns

  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.dns.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60

  allow_overwrite = true # ACM may reuse validation names across cert recreates
}

# --- Validation wait (blocks until cert is ISSUED) -----------------------

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]

  timeouts {
    create = "10m"
  }
}
