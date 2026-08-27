# Cross-account roles the BE assumes to write `_acme-challenge` TXT records
# into the public zones, which live here in Shared.
#
# One role PER ENV, for blast radius: staging and production zones share an
# account, so a role scoped to both would let staging rewrite production DNS.
#
# Every role is scoped three ways, and all three matter:
#   - resource     exactly one hosted zone
#   - RecordTypes  TXT only, so a stolen session cannot move an A/ALIAS
#   - Names        `_acme-challenge.*`, so it cannot touch SPF or DMARC
#
# Zones are looked up, never declared: this file grants access to zones it
# does not own, and a plan that fails on a missing zone is the better outcome.

locals {
  # env -> (zone it may write, principal allowed to assume). Adding an env
  # is one entry plus the role ARN on that env's task definition.
  #
  # Principals differ by env: staging and production are ECS task roles,
  # dev is the local engineer's IAM user.
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

  # ACCOUNT ROOT narrowed to one caller by aws:PrincipalArn — NOT "anyone in
  # the account". Effective access equals naming the principal directly, and
  # it avoids two failure modes of that idiom:
  #
  #   1. IAM validates principals at role CREATION, so naming a not-yet
  #      deployed task role fails the apply. Root always exists.
  #   2. A named principal is stored as its unique id, not its ARN, so
  #      recreating the task role silently breaks trust. ARNs survive.
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
        # ForAllValues is REQUIRED, not stylistic: a ChangeBatch is
        # multi-valued, so plain StringEquals would pass a batch that merely
        # CONTAINS a compliant change — letting an A-record edit ride along
        # beside a legitimate TXT one.
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