# Fat-finger guard: deny RunInstances + RDS Create/Modify + ElastiCache
# Create/Modify when the requested instance/node type matches a "giant"
# pattern. Catches the typo case ("oh I meant db.t4g.micro, not db.r6g.16xlarge")
# without limiting normal iteration.
#
# Caller attaches the policy ARN to whichever principal needs the guard:
# the GitHub Actions deploy role in staging/production; the meandr-dev
# IAM user in development. Both via aws_iam_role_policy_attachment /
# aws_iam_user_policy_attachment in the caller — no provider-level
# coupling here.
#
# Bypass procedure (if a real need ever surfaces): update the relevant
# pattern list input in the caller to drop the offending pattern from
# the deny list, re-apply, do the resource bump, optionally re-tighten
# after. The deny list change shows up in a TF diff, which is the
# audit trail that makes the bypass defensible.

data "aws_iam_policy_document" "deny" {
  # EC2 — RunInstances + ModifyInstanceAttribute. The condition key
  # `ec2:InstanceType` works on both actions; ForAnyValue:StringLike
  # is the right matcher because the request can be a single string,
  # but the IAM evaluator handles either case under ForAnyValue.
  statement {
    sid    = "DenyLargeEC2"
    effect = "Deny"
    actions = [
      "ec2:RunInstances",
      "ec2:ModifyInstanceAttribute",
    ]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringLike"
      variable = "ec2:InstanceType"
      values   = var.denied_instance_patterns
    }
  }

  # RDS — CreateDBInstance + ModifyDBInstance. `rds:DatabaseClass`
  # condition key (note: not `DBInstanceClass` despite the API field
  # name — this is the IAM key spelling). Same StringLike matcher.
  statement {
    sid    = "DenyLargeRDS"
    effect = "Deny"
    actions = [
      "rds:CreateDBInstance",
      "rds:ModifyDBInstance",
    ]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringLike"
      variable = "rds:DatabaseClass"
      values   = var.denied_rds_class_patterns
    }
  }

  # ElastiCache — both single-node Cluster and ReplicationGroup paths.
  # `elasticache:CacheNodeType` is the condition key for both Create
  # and Modify actions across both APIs.
  statement {
    sid    = "DenyLargeElastiCache"
    effect = "Deny"
    actions = [
      "elasticache:CreateCacheCluster",
      "elasticache:CreateReplicationGroup",
      "elasticache:ModifyCacheCluster",
      "elasticache:ModifyReplicationGroup",
    ]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringLike"
      variable = "elasticache:CacheNodeType"
      values   = var.denied_elasticache_node_patterns
    }
  }
}

resource "aws_iam_policy" "deny" {
  name        = var.name
  description = var.description
  policy      = data.aws_iam_policy_document.deny.json
}
