# ACME DNS-01 delegation — cross-account roles the BE assumes to write
# `_acme-challenge` TXT records into the public zones.
#
# The zones live here in Shared, the workloads that need them run in the
# other accounts. Rather than granting those accounts Route 53 access
# directly, each env gets its OWN role here, trusting only that env's
# principal. The point of the split is blast radius: staging and
# production zones share an account, so a single role scoped to both
# would let staging credentials rewrite production DNS.
#
# Every role is scoped three ways, and all three matter:
#   - resource   → exactly one hosted zone
#   - RecordTypes→ TXT only, so a stolen session can't move an A/ALIAS
#                  record and hijack traffic
#   - Names      → `_acme-challenge.*` only, so it can't touch a live
#                  hostname even as TXT (SPF/DMARC/verification records)
#
# The zones are operator-managed (see main.tf header), so all three are
# looked up by name rather than declared. That is deliberate: this file
# grants access to zones it does not own, and creating one by accident
# here would be worse than a failed plan — a plan that fails because a
# zone is missing says exactly what to go do.

locals {
  # env → (zone it may write, principal allowed to assume). Adding an env
  # is one entry plus the role ARN on that env's task definition.
  #
  # Principals differ by env on purpose: staging and production run as
  # ECS task roles, dev runs as the local engineer's IAM user. Trust
  # names the exact principal, never the account root — root would let
  # ANY role in that account assume this one.
  #
  # meandr.dev is a real, delegated TLD (and HSTS-preloaded), so unlike
  # the meandr.local sandbox it replaced, a development order can
  # actually complete instead of failing at validation.
  acme_envs = {
    staging = {
      zone       = "meandr.live"
      account_id = "259534890849"
      principal  = "arn:aws:iam::259534890849:role/meandr-api-task-staging"
    }
    production = {
      zone       = "meandr.io"
      account_id = "393686273464"
      principal  = "arn:aws:iam::393686273464:role/meandr-api-task-production"
    }
    development = {
      zone       = "meandr.dev"
      account_id = "238020582774"
      principal  = "arn:aws:iam::238020582774:user/dev/meandr-dev"
    }
  }
}

data "aws_route53_zone" "acme" {
  for_each = local.acme_envs

  name         = each.value.zone
  private_zone = false
}

# --- Roles --------------------------------------------------------------

resource "aws_iam_role" "acme_dns" {
  for_each = local.acme_envs

  name        = "meandr-acme-dns-${each.key}"
  description = "ACME DNS-01 challenge writes into ${each.value.zone}, assumed by ${each.key}"

  # Principal is the workload ACCOUNT ROOT, narrowed to the exact caller
  # by aws:PrincipalArn. Effective access is identical to naming the
  # principal directly, and it avoids two failure modes that idiom has:
  #
  #   1. Ordering. IAM validates principals when a role is CREATED, so
  #      naming a not-yet-deployed task role fails the apply outright
  #      (`MalformedPolicyDocument: Invalid principal in policy`).
  #      production's BE isn't deployed yet; root always exists, so this
  #      file no longer has to know or care.
  #   2. Recreation. A directly-named principal is stored internally as
  #      its unique id, NOT its ARN — delete and recreate the task role
  #      under the same name and the trust silently stops matching. The
  #      condition compares ARNs, which survive recreation.
  #
  # Root here does NOT mean "anyone in that account": it delegates to
  # that account's IAM, and the condition then admits exactly one ARN.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${each.value.account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = {
        ArnEquals = { "aws:PrincipalArn" = each.value.principal }
      }
    }]
  })

  tags = merge(var.tags, {
    Name = "meandr-acme-dns-${each.key}"
  })
}

resource "aws_iam_role_policy" "acme_dns" {
  for_each = local.acme_envs

  name = "acme-dns-01"
  role = aws_iam_role.acme_dns[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The write, fenced to TXT records named _acme-challenge.*.
        # Both condition keys are multi-valued — a single ChangeBatch can
        # carry several changes — so ForAllValues is required: it fails
        # the whole batch unless EVERY entry satisfies the condition.
        # StringEquals/StringLike alone would pass a batch that merely
        # CONTAINS a compliant change, letting an A-record edit ride
        # along beside a legitimate TXT one.
        Sid      = "AcmeChallengeWrite"
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = data.aws_route53_zone.acme[each.key].arn
        Condition = {
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsRecordTypes" = ["TXT"]
          }
          "ForAllValues:StringLike" = {
            # Normalized names are lowercased with the trailing dot
            # stripped, so this matches _acme-challenge.<anything> in
            # this zone — including the wildcard's, which validates
            # against the same name as the apex.
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = ["_acme-challenge.*"]
          }
        }
      },
      {
        # Read-back so the client can confirm its own TXT landed before
        # telling the CA to validate. Unconditioned: the condition keys
        # above exist only for Change, and listing a zone this role
        # already writes to reveals nothing further.
        Sid      = "AcmeChallengeRead"
        Effect   = "Allow"
        Action   = "route53:ListResourceRecordSets"
        Resource = data.aws_route53_zone.acme[each.key].arn
      },
      {
        # Polling INSYNC on the change we just submitted. Change ids are
        # opaque and not zone-scopable in IAM, hence the wildcard — it
        # grants status reads only, no mutation.
        Sid      = "AcmeChangePolling"
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
    ]
  })
}

output "acme_dns_role_arns" {
  description = "env → ACME DNS role ARN. staging/production are wired by Terraform into the task definition; development goes into .env.development as MEANDR_ACME_DNS_ROLE_ARN."
  value       = { for k, r in aws_iam_role.acme_dns : k => r.arn }
}