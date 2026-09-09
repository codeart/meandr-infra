# One NAT instance, serving whatever route tables the caller points at it.
#
# Replaces a NAT gateway's fixed hourly charge, which is ~$33-38/month per
# AZ address against ~$3.50 for a t4g.nano — on staging peaks of 3.5 Mbps
# and 402 packets/sec. Cutover and rollback: docs/runbooks/nat_cutover.md.
#
# The EIP is what persists. The interface belongs to the instance and is
# replaced with it — Terraform moves the route to the new one — but the
# address does not change, so an allow-list stays correct across a rebuild.
#
# A standalone ENI would have held the route target still too, and was the
# first design here. It cannot work: aws_instance re-asserts
# source_dest_check = true on every apply and the provider refuses to let
# you set it to false while the interface is separate.

data "aws_ssm_parameter" "al2023_arm" {
  count = var.ami_id == "" ? 1 : 0
  # The same alias resolves in every region, so multi-region needs no AMI
  # copying and no per-region id map.
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  ami  = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.al2023_arm[0].value
  name = "nat-${var.az}"

  metric_namespace = "meandr/nat"
}

# --- Security -----------------------------------------------------------

resource "aws_security_group" "main" {
  name        = local.name
  description = "NAT instance for ${var.az}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = local.name })
}

# Everything from inside the VPC, nothing from outside. Ports cannot be
# narrowed here: this carries every protocol a workload egresses.
resource "aws_vpc_security_group_ingress_rule" "vpc" {
  security_group_id = aws_security_group.main.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
  description       = "Egress traffic from this VPC"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.main.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Forwarded traffic to the internet"
}

# --- Address and interface ----------------------------------------------

# The EIP outlives the instance, so the egress address survives a
# replacement even though the interface underneath does not.
resource "aws_eip" "main" {
  domain = "vpc"

  tags = merge(var.tags, { Name = "NAT EIP ${var.az}" })
}

resource "aws_eip_association" "main" {
  allocation_id = aws_eip.main.id
  instance_id   = aws_instance.main.id
}

# --- Instance -----------------------------------------------------------

# SSM Session Manager is the only way onto this box. No SSH key, no port
# 22, and the audit trail comes free.
resource "aws_iam_role" "main" {
  name = local.name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = local.name })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.main.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# PutMetricData takes no resource, but it does take a namespace condition —
# so a compromised NAT box cannot write over another component's metrics.
resource "aws_iam_role_policy" "metrics" {
  name = "nat-metrics"
  role = aws_iam_role.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "cloudwatch:PutMetricData"
      Resource  = "*"
      Condition = { StringEquals = { "cloudwatch:namespace" = local.metric_namespace } }
    }]
  })
}

resource "aws_iam_instance_profile" "main" {
  name = local.name
  role = aws_iam_role.main.name
}

# eu-central-1 runs tight on the small Graviton sizes, and a NAT that
# cannot launch is a region with no egress — so the slot is held before it
# is needed, not hoped for at replacement time.
#
# TARGETED, where valkey-region uses open: Valkey holds open reservations
# for the same types in the same zones, and an open one here would be
# consumed by whichever instance launched first. Targeted also means the
# instance below references it, so Terraform orders the two without a
# depends_on — see the note on that resource.
resource "aws_ec2_capacity_reservation" "main" {
  instance_type           = var.instance_type
  instance_platform       = "Linux/UNIX"
  availability_zone       = var.az
  instance_count          = 1
  end_date_type           = "unlimited"
  instance_match_criteria = "targeted"

  tags = merge(var.tags, { Name = local.name })
}

resource "aws_instance" "main" {
  ami                  = local.ami
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.main.name

  # An attribute reference, deliberately, rather than depends_on: the
  # reference orders reservation before instance while leaving the AMI
  # data source resolvable at plan time. depends_on would defer it,
  # local.user_data would go unknown, and user_data_replace_on_change
  # would stop firing without saying so. Same trap as valkey-region.
  capacity_reservation_specification {
    capacity_reservation_target {
      capacity_reservation_id = aws_ec2_capacity_reservation.main.id
    }
  }

  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.main.id]

  # What makes this a router rather than a host: with the check on, EC2
  # drops every packet not addressed to the instance, which is all of them.
  #
  # It MUST be set here and the interface must belong to the instance. Set
  # on a standalone aws_network_interface instead, aws_instance asserts its
  # own default of `true` on every apply, always afterwards — a NAT that
  # silently forwards nothing, and a perpetual true -> false diff.
  # Confirmed in CloudTrail, 2026-09-08.
  source_dest_check = false

  user_data_base64            = base64gzip(local.user_data)
  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  tags = merge(var.tags, {
    Name = local.name
    Role = "nat"
  })

  lifecycle {
    # The AMI alias moves whenever AWS publishes a new Amazon Linux image.
    # Without this an unrelated apply weeks later would replace this
    # instance, taking a region's egress with it for the two minutes it
    # takes to boot. Replacement is deliberate: bump ami_id, or taint.
    ignore_changes = [ami]
  }
}

# A hung instance keeps its ENI, so the route still points at a box that
# forwards nothing — the one failure the ENI design cannot absorb. Reboot
# is the cheapest thing that clears it without an ASG.
resource "aws_cloudwatch_metric_alarm" "instance_health" {
  alarm_name          = "${local.name}-status-check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions          = { InstanceId = aws_instance.main.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = ["arn:aws:automate:${data.aws_region.current.region}:ec2:reboot"]

  tags = merge(var.tags, { Name = local.name })
}

# Conntrack exhaustion refuses NEW connections while established ones keep
# working, so it surfaces as intermittent failures a long way from here.
# 80% is a capacity warning, not an incident — raise nf_conntrack_max or
# the instance size.
resource "aws_cloudwatch_metric_alarm" "conntrack" {
  alarm_name          = "${local.name}-conntrack"
  namespace           = local.metric_namespace
  metric_name         = "ConntrackPercent"
  dimensions          = { InstanceId = aws_instance.main.id }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_topic_arns

  tags = merge(var.tags, { Name = local.name })
}

data "aws_region" "current" {}

# The one setting that turns this box into a black hole, asserted on every
# plan and apply.
#
# EC2 enforces source/dest checking ABOVE the OS, so when it is on the
# instance looks perfect — ip_forward set, masquerade rule loaded, tcpdump
# silent because nothing is delivered — and every forwarded packet
# disappears with no log line anywhere. It cost an evening on 2026-09-08.
# A check block is the cheapest thing that makes it speak.
check "forwards_packets" {
  data "aws_instance" "current" {
    instance_id = aws_instance.main.id
  }

  assert {
    condition     = data.aws_instance.current.source_dest_check == false
    error_message = "${local.name}: source/dest check is ON — this NAT silently forwards nothing."
  }
}
