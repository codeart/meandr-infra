# Org-level fat-finger guard: a Service Control Policy denying RunInstances /
# RDS Create-Modify / ElastiCache Create-Modify when the requested instance or
# node type matches a "giant" pattern. Sister to `iam-instance-size-guard`,
# but applied at the Organizations layer where no IAM principal in a member
# account (including root) can bypass it.
#
# Important semantic differences vs the IAM module:
#
#   1. SCPs DO NOT apply to the Organizations management account. If the
#      master ever runs workloads, the IAM-level guard is still the right
#      tool there.
#   2. SCPs are absolute denies — there is no "user can override" model
#      inside a member account. If a real need surfaces, the bypass paths
#      are: (a) edit the patterns input + re-apply (audit trail = TF diff),
#      (b) detach the SCP from the target OU/account in the Organizations
#      console (audit trail = CloudTrail DetachPolicy event).
#   3. SCP JSON is capped at 5,120 chars (smaller than IAM's 6,144). The
#      three statements below comfortably fit.
#
# Prerequisite: SERVICE_CONTROL_POLICY must be enabled on the target Root
# before any policy can attach. One-time bootstrap, run from the master:
#
#   aws organizations enable-policy-type \
#     --root-id <r-xxxx> --policy-type SERVICE_CONTROL_POLICY \
#     --profile meandr-master
#
# Not expressed in TF because the only resource that manages it
# (`aws_organizations_organization`) would import the entire org into this
# state file — more risk than the one-time CLI call is worth.

data "aws_iam_policy_document" "deny" {
  # EC2 — RunInstances + ModifyInstanceAttribute. Same condition key
  # (`ec2:InstanceType`) and same matcher (`ForAnyValue:StringLike`) as
  # the IAM-level module; the SCP policy language is the same dialect.
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

  # RDS — CreateDBInstance + ModifyDBInstance. Note IAM key is
  # `rds:DatabaseClass`, not `DBInstanceClass`.
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

  # ElastiCache — both single-node Cluster and ReplicationGroup paths,
  # Create and Modify.
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

resource "aws_organizations_policy" "deny" {
  name        = var.name
  description = var.description
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny.json
  tags        = var.tags
}

resource "aws_organizations_policy_attachment" "targets" {
  for_each = toset(var.target_ids)

  policy_id = aws_organizations_policy.deny.id
  target_id = each.value
}
