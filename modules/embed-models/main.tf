# Meandr's embedding model (product/hosted_models.md): a spot T4G node always
# on, replaced on AWS's rebalance hint; a T4 or L4 on demand while it has none;
# and the CPU node, until the T4G has proven itself.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ECS-optimized AL2023 for Docker, and on the GPU image NVIDIA's driver and runtime.
data "aws_ssm_parameter" "cpu_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id"
}

data "aws_ssm_parameter" "gpu_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/gpu/recommended/image_id"
}

# The T4G's host is ARM, which no ECS GPU image serves: AWS's Deep Learning
# image brings NVIDIA's driver, Docker and its container toolkit.
data "aws_ssm_parameter" "arm_gpu_ami" {
  name = "/aws/service/deeplearning/ami/arm64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id"
}

locals {
  region        = data.aws_region.current.region
  account       = data.aws_caller_identity.current.account_id
  cpu_name      = "meandr-embed-cpu"
  primary_name  = "meandr-embed-primary"
  fallback_name = "meandr-embed-fallback"
  registry      = "${local.account}.dkr.ecr.${local.region}.amazonaws.com"
  tags          = merge(var.tags, { "meandr:role" = "embed-model" })

  # The longest text any node embeds; a longer one is refused. TEI's memory
  # per text grows with its square: the CPU node's two servers fit 16 GiB at 4,096.
  max_tokens = 4096

  # The CPU node and the fallback run in one region only; the T4G in each.
  cpu      = var.models.cpu_type != null
  fallback = length(var.models.fallback_types) > 0
  gpu_amis = merge({ (local.primary_name) = data.aws_ssm_parameter.arm_gpu_ami.value },
  local.fallback ? { (local.fallback_name) = data.aws_ssm_parameter.gpu_ami.value } : {})
  gpu_types = merge({ (local.primary_name) = var.models.primary_types },
  local.fallback ? { (local.fallback_name) = var.models.fallback_types } : {})

  # Each GPU group's subnets whose zone offers one of its types.
  gpu_subnets = { for group, offered in data.aws_ec2_instance_type_offerings.gpu :
  group => [for id, subnet in data.aws_subnet.gpu : id if contains(offered.locations, subnet.availability_zone)] }

  group_arns = [for g in [local.cpu_name, local.primary_name, local.fallback_name] :
  "arn:aws:autoscaling:${local.region}:${local.account}:autoScalingGroup:*:autoScalingGroupName/${g}"]
}

# --- Image and model -----------------------------------------------------

# TEI's images and the model, copied here once: nodes pull both through the
# VPC's free S3 endpoint, never the NAT, whose micro instances a 3 GB CUDA image
# per GPU boot would saturate.
resource "aws_ecr_repository" "tei" {
  name                 = "mirror/text-embeddings-inference"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.tags, { Name = "TEI mirror" })
}

resource "aws_s3_bucket" "models" {
  bucket = "meandr-models-${local.region}-${var.env}"

  tags = merge(local.tags, { Name = "Embedding models" })
}

resource "aws_s3_bucket_ownership_controls" "models" {
  bucket = aws_s3_bucket.models.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "models" {
  bucket                  = aws_s3_bucket.models.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- Network -------------------------------------------------------------

resource "aws_security_group" "node" {
  # A prefix, so a replacement is made before the old group is let go.
  name_prefix = "meandr-embed-model-"
  description = "Embedding model nodes - the gateway only"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "meandr-embed-model" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_gateway" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.gateway.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8083
  description                  = "The gateway"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "ECR, S3 and AWS APIs"
}

# --- Identity ------------------------------------------------------------

# Session Manager for an operator; pulls of the mirror and the model; the
# lifecycle call that puts a node in service.
resource "aws_iam_role" "node" {
  name = "meandr-embed-model-${var.env}-${local.region}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "meandr-embed-model" })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ready" {
  name = "lifecycle-ready"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "autoscaling:CompleteLifecycleAction"
        Resource = local.group_arns
      },
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = aws_ecr_repository.tei.arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.models.arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.models.arn}/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "meandr-embed-model-${var.env}-${local.region}"
  role = aws_iam_role.node.name
}

# --- Launch templates ----------------------------------------------------

resource "aws_launch_template" "cpu" {
  count = local.cpu ? 1 : 0

  name          = local.cpu_name
  image_id      = data.aws_ssm_parameter.cpu_ami.value
  instance_type = var.models.cpu_type

  update_default_version = true

  iam_instance_profile { arn = aws_iam_instance_profile.node.arn }
  vpc_security_group_ids = [aws_security_group.node.id]

  user_data = base64encode(templatefile("${path.module}/files/cpu.sh.tftpl", {
    registry   = local.registry
    image      = "${aws_ecr_repository.tei.repository_url}:cpu-arm64-${var.models.tei_version}"
    bucket     = aws_s3_bucket.models.id
    model      = var.models.model
    max_tokens = local.max_tokens
    region     = local.region
    group      = local.cpu_name
  }))

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = 40
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Containers are one hop away and get no instance credentials.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = local.cpu_name })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = local.cpu_name })
  }

  # AWS's newer AMI only on a deliberate replacement, not on any apply.
  lifecycle {
    ignore_changes = [image_id]
  }
}

# Every GPU node boots the same script, which picks TEI's build for its CPU
# and GPU: the T4G's from the ARM image, a T4's or an L4's from the ECS one.
resource "aws_launch_template" "gpu" {
  for_each = local.gpu_amis

  name     = each.key
  image_id = each.value

  update_default_version = true

  iam_instance_profile { arn = aws_iam_instance_profile.node.arn }
  vpc_security_group_ids = [aws_security_group.node.id]

  user_data = base64encode(templatefile("${path.module}/files/gpu.sh.tftpl", {
    registry    = local.registry
    mirror      = aws_ecr_repository.tei.repository_url
    tei_version = var.models.tei_version
    bucket      = aws_s3_bucket.models.id
    model       = var.models.model
    reranker    = coalesce(var.models.reranker, "")
    max_tokens  = local.max_tokens
    region      = local.region
    group       = each.key
  }))

  # CUDA images are large: the AMIs' roots would fill.
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = 100
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = each.key })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = each.key })
  }

  lifecycle {
    ignore_changes = [image_id]
  }
}

# --- Groups --------------------------------------------------------------

# Frankfurt offers the T4G in one zone of three.
data "aws_ec2_instance_type_offerings" "gpu" {
  for_each      = local.gpu_types
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = each.value
  }
}

data "aws_subnet" "gpu" {
  for_each = toset(var.gpu_subnet_ids)
  id       = each.value
}

moved {
  from = aws_launch_template.cpu
  to   = aws_launch_template.cpu[0]
}

moved {
  from = aws_autoscaling_group.cpu
  to   = aws_autoscaling_group.cpu[0]
}

# One node, replaced by launching first: the new one is in service before
# the old one goes, on a refresh as after a failure.
resource "aws_autoscaling_group" "cpu" {
  count = local.cpu ? 1 : 0

  name                = local.cpu_name
  min_size            = var.parked ? 0 : 1
  max_size            = var.parked ? 0 : 2
  desired_capacity    = var.parked ? 0 : 1
  vpc_zone_identifier = var.subnet_ids

  launch_template {
    id      = aws_launch_template.cpu[0].id
    version = aws_launch_template.cpu[0].latest_version
  }

  initial_lifecycle_hook {
    name                 = "ready"
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
    default_result       = "ABANDON"
    heartbeat_timeout    = 900
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
    }
  }

  dynamic "tag" {
    for_each = merge(local.tags, { Name = local.cpu_name })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }
}

# One spot T4G, always wanted, from its types in the order listed. On a
# rebalance hint the group launches the replacement, waits for it to answer
# (the ready hook), then terminates the node at risk.
resource "aws_autoscaling_group" "primary" {
  name                = local.primary_name
  min_size            = var.parked ? 0 : 1
  max_size            = var.parked ? 0 : 2
  desired_capacity    = var.parked ? 0 : 1
  capacity_rebalance  = true
  vpc_zone_identifier = local.gpu_subnets[local.primary_name]

  # Spot capacity is AWS's to give, and the gateways stand in without it.
  wait_for_capacity_timeout = "0"

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "capacity-optimized-prioritized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.gpu[local.primary_name].id
        version            = aws_launch_template.gpu[local.primary_name].latest_version
      }

      dynamic "override" {
        for_each = var.models.primary_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  initial_lifecycle_hook {
    name                 = "ready"
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
    default_result       = "ABANDON"
    heartbeat_timeout    = 900
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
    }
  }

  dynamic "tag" {
    for_each = merge(local.tags, { Name = local.primary_name })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }
}

# On demand, 0 or 1 node, in the order the root lists: the alarm below runs it
# while no region has a T4G in service. One region has it, and every gateway uses it.
resource "aws_autoscaling_group" "fallback" {
  count = local.fallback ? 1 : 0

  name                = local.fallback_name
  min_size            = 0
  max_size            = var.parked ? 0 : 1
  desired_capacity    = 0
  vpc_zone_identifier = local.gpu_subnets[local.fallback_name]

  mixed_instances_policy {
    instances_distribution {
      on_demand_allocation_strategy            = "prioritized"
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 100
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.gpu[local.fallback_name].id
        version            = aws_launch_template.gpu[local.fallback_name].latest_version
      }

      dynamic "override" {
        for_each = var.models.fallback_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  initial_lifecycle_hook {
    name                 = "ready"
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
    default_result       = "ABANDON"
    heartbeat_timeout    = 900
  }

  dynamic "tag" {
    for_each = merge(local.tags, { Name = local.fallback_name })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# The gateway reports the T4G nodes in service in every region: two minutes
# with none start the fallback, and one back stops it. Missing data changes nothing.
resource "aws_autoscaling_policy" "fallback" {
  for_each = local.fallback ? { start = 1, stop = 0 } : {}

  name                   = "primary-${each.key == "start" ? "missing" : "back"}"
  autoscaling_group_name = aws_autoscaling_group.fallback[0].name
  policy_type            = "StepScaling"
  adjustment_type        = "ExactCapacity"

  step_adjustment {
    scaling_adjustment          = each.value
    metric_interval_upper_bound = each.key == "start" ? 0 : null
    metric_interval_lower_bound = each.key == "start" ? null : 0
  }
}

resource "aws_cloudwatch_metric_alarm" "primary_missing" {
  count = local.fallback ? 1 : 0

  alarm_name          = "${local.primary_name}-missing"
  alarm_description   = "No T4G in service in any region: the fallback runs until one is back"
  namespace           = "Meandr/Embed"
  metric_name         = "PrimaryNodes"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "ignore"
  alarm_actions       = [aws_autoscaling_policy.fallback["start"].arn]
  ok_actions          = [aws_autoscaling_policy.fallback["stop"].arn]

  tags = merge(local.tags, { Name = "${local.primary_name}-missing" })
}

# --- Interruption drills -------------------------------------------------

# AWS FIS sends the T4G node a real spot interruption: "later" gives the
# rebalance hint 5 minutes ahead, as AWS often does; "now" only the 2-minute notice.
resource "aws_iam_role" "fis" {
  name = "meandr-embed-fis-${var.env}-${local.region}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "meandr-embed-fis" })
}

resource "aws_iam_role_policy" "fis" {
  name = "interrupt-gpu"
  role = aws_iam_role.fis.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "ec2:SendSpotInstanceInterruptions"
        Resource  = "arn:aws:ec2:${local.region}:${local.account}:instance/*"
        Condition = { StringEquals = { "aws:ResourceTag/aws:autoscaling:groupName" = local.primary_name } }
      },
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
    ]
  })
}

resource "aws_fis_experiment_template" "gpu_interrupt" {
  for_each = { later = "PT5M", now = "PT2M" }

  description = "Interrupt the spot T4G node, ${each.value} ahead"
  role_arn    = aws_iam_role.fis.arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "interrupt"
    action_id = "aws:ec2:send-spot-instance-interruptions"

    parameter {
      key   = "durationBeforeInterruption"
      value = each.value
    }

    target {
      key   = "SpotInstances"
      value = "gpu"
    }
  }

  target {
    name           = "gpu"
    resource_type  = "aws:ec2:spot-instance"
    selection_mode = "ALL"

    resource_tag {
      key   = "aws:autoscaling:groupName"
      value = local.primary_name
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }

  tags = merge(local.tags, { Name = "meandr-embed-gpu-interrupt-${each.key}" })
}
