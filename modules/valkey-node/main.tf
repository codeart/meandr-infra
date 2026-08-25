# One self-hosted Valkey node — master, in-region replica, or edge replica.
#
# One module rather than a cluster module because the nodes do not share a
# VPC: the API pair sits in one region and every edge replica in its own,
# reachable only over peering. A cluster module would have to span
# providers and would still be instantiated once per region.
#
# Replaces ElastiCache for the CONFIG tier. Global Datastore caps at three
# regions, excludes t-family entirely, and costs several times this; see
# events/flows/client-capability-floor.md's sibling note in
# meandr-vision-v1.md §9.1.

data "aws_ssm_parameter" "al2023_arm" {
  count = var.ami_id == "" ? 1 : 0
  # The same alias resolves in every region, so multi-region needs no AMI
  # copying and no per-region id map.
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  ami = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.al2023_arm[0].value

  # Every name in this module derives from (fleet, node) — nothing is
  # passed in pre-composed. Two fleets share a VPC, a private zone and a
  # cert, so a name without the fleet in it is a collision waiting for the
  # second fleet to land.
  #
  # Two namings, deliberately, because they answer to different rules.
  # AWS resource names take dashes: valkey-config-a. DNS nests under a
  # per-family subdomain: config-a.valkey.<zone> — which is what lets one
  # `*.valkey.<zone>` SAN cover every fleet this environment ever grows.
  node_name = "valkey-${var.fleet}-${var.node}"
  dns_root  = "valkey.${var.dns_zone_name}"
  hostname  = "${var.fleet}-${var.node}.${local.dns_root}"

  source_key = "valkey/${var.valkey_version}/valkey-src.tar.gz"
  source_uri = "s3://${var.valkey_source_bucket}/${local.source_key}"
}

# --- Security -----------------------------------------------------------

resource "aws_security_group" "main" {
  name        = local.node_name
  description = "Valkey ${var.fleet} fleet, node ${var.node}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = local.node_name })
}

resource "aws_vpc_security_group_ingress_rule" "valkey" {
  for_each = toset(var.client_cidrs)

  security_group_id = aws_security_group.main.id
  cidr_ipv4         = each.value
  from_port         = 6379
  to_port           = 6379
  ip_protocol       = "tcp"
  description       = "Valkey"
}

# Replicas connect to the master on 6379; Sentinels gossip on 26379 and
# also talk to every node they monitor. Both are opened to the same
# ranges — narrowing further would mean tracking which peer is which,
# which changes on every promotion.
resource "aws_vpc_security_group_ingress_rule" "sentinel" {
  for_each = toset(var.client_cidrs)

  security_group_id = aws_security_group.main.id
  cidr_ipv4         = each.value
  from_port         = 26379
  to_port           = 26379
  ip_protocol       = "tcp"
  description       = "Sentinel"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.main.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Package repo at boot, replication out, Secrets Manager"
}

# --- Instance role ------------------------------------------------------
#
# The AUTH token is fetched at boot rather than passed in user-data:
# user-data is readable from instance metadata by anything running on the
# box, and it persists for the instance's whole life.

resource "aws_iam_role" "main" {
  name = local.node_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = local.node_name })
}

resource "aws_iam_role_policy" "secrets" {
  name = "valkey-secrets"
  role = aws_iam_role.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = [var.auth_secret_arn, var.tls_secret_arn]
    }]
  })
}

# Scoped to the one object, not the bucket: this role has no business
# reading anything else that lands there, and the source it may read is
# already named by the version pin.
resource "aws_iam_role_policy" "source" {
  name = "valkey-source"
  role = aws_iam_role.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:GetObject"
      Resource = "arn:aws:s3:::${var.valkey_source_bucket}/${local.source_key}"
    }]
  })
}

# PutMetricData cannot be scoped: no resource ARN, and the real call does
# not carry cloudwatch:namespace in its request context, so a condition on
# it denies everything (verified with simulate-principal-policy). Used by
# both the CloudWatch agent and the INFO-scraping timer.
resource "aws_iam_role_policy" "metrics" {
  name = "valkey-metrics"
  role = aws_iam_role.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "cloudwatch:PutMetricData"
      Resource = "*"
    }]
  })
}

# Write-only, and only under this fleet's prefix: a node has no reason to
# read a backup back, and less to touch another fleet's.
resource "aws_iam_role_policy" "backup" {
  count = var.backup_bucket != "" ? 1 : 0

  name = "valkey-backup"
  role = aws_iam_role.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = "arn:aws:s3:::${var.backup_bucket}/${var.fleet}/*"
    }]
  })
}

# Sentinel's reconfig script repoints the master record on promotion, and
# without this it fails — silently, into a log nobody reads, on the one
# day it matters. Every edge replica would stay pointed at a node that is
# no longer master.
#
# Only on nodes that run Sentinel: a plain replica never promotes anything
# and has no reason to hold a write on the zone.
resource "aws_iam_role_policy" "promote_dns" {
  count = var.run_sentinel ? 1 : 0

  name = "valkey-promote-dns"
  role = aws_iam_role.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "route53:ChangeResourceRecordSets"
      Resource = "arn:aws:route53:::hostedzone/${var.dns_zone_id}"
      Condition = {
        # Scoped to the ONE record it exists to move. A promotion script
        # that can rewrite the whole internal zone is a larger capability
        # than the job needs.
        "ForAllValues:StringEquals" = {
          "route53:ChangeResourceRecordSetsNormalizedRecordNames" = [local.master_record]
          "route53:ChangeResourceRecordSetsRecordTypes"           = ["CNAME"]
        }
      }
    }]
  })
}

# SSM Session Manager: the only way onto these boxes. No SSH key, no port
# 22, and the audit trail comes free.
#
# OS packages update over SSM. Valkey itself does NOT: it comes from a
# pinned artifact, so a version bump replaces the instance
# (user_data_replace_on_change). That is the behaviour we want — a clean
# node resyncing from its master, replicas first and master last, rather
# than a restart-in-place on the one process holding the fleet's state.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.main.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "main" {
  name = local.node_name
  role = aws_iam_role.main.name
}

# --- Node ---------------------------------------------------------------

resource "aws_instance" "main" {
  ami                    = local.ami
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.main.id]
  iam_instance_profile   = aws_iam_instance_profile.main.name

  # gzip+base64, because EC2 caps user-data at 16 KiB and this script is
  # past it in plain text — it is comment-heavy by design and carries two
  # base64-embedded helpers. cloud-init detects the gzip magic and
  # decompresses transparently, so nothing on the instance changes.
  #
  # Compressing rather than trimming: the comments are the only place the
  # reasoning behind these settings survives, and a node's boot script is
  # exactly where someone reads it at 3am.
  user_data_base64            = base64gzip(local.user_data)
  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.data_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  timeouts {
    create = var.create_timeout
  }

  tags = merge(var.tags, {
    Name = local.node_name
    Role = var.role
  })

  lifecycle {
    # The AMI alias moves whenever AWS publishes a new Amazon Linux image.
    # Without this, an unrelated `terraform apply` weeks later would
    # replace a live Valkey node because a base image changed — losing its
    # data and, if it was the master, forcing a failover nobody asked for.
    # Replacement is deliberate: bump valkey_version, or taint.
    ignore_changes = [ami]
  }
}

# The node's own name. Stable, and NOT the name clients use for the
# master — that record is owned by whoever runs the failover, because it
# has to move on promotion and Terraform must not fight it.
resource "aws_route53_record" "node" {
  zone_id = var.dns_zone_id
  name    = local.hostname
  type    = "A"
  ttl     = 60
  records = [aws_instance.main.private_ip]
}

data "aws_region" "current" {}
