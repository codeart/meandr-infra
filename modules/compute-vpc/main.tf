# The hosted-node fleet substrate (hosted_nodes.md §2-4,
# network_allocation.md §3): one compute VPC on the region's first block,
# private-only instances, own NAT egress, peered ONLY to the main VPC.

locals {
  az_index = { for i, az in var.azs : az => i }
  az_names = { for az in var.azs : az => "${var.region}${az}" }

  # network_allocation.md §3: public x.<i>.0/24, private 64/128/192.0/18.
  public_cidrs  = { for az, i in local.az_index : az => "${var.block}.${i}.0/24" }
  private_cidrs = { for az, i in local.az_index : az => "${var.block}.${64 * (i + 1)}.0/18" }

  base_tags = merge(var.tags, { Component = "hosted-fleet" })
}

resource "aws_vpc" "main" {
  cidr_block           = "${var.block}.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.base_tags, { Name = "Hosted fleet - ${var.env}" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.base_tags, { Name = "Hosted fleet IGW" })
}

resource "aws_subnet" "public" {
  for_each = local.az_index

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_cidrs[each.key]
  availability_zone = local.az_names[each.key]

  tags = merge(local.base_tags, { Name = "hosted-public-${each.key}" })
}

resource "aws_subnet" "private" {
  for_each = local.az_index

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[each.key]
  availability_zone = local.az_names[each.key]

  tags = merge(local.base_tags, { Name = "hosted-private-${each.key}" })
}

# --- Routing ------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.base_tags, { Name = "hosted-public" })
}

resource "aws_route" "public_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = local.az_index

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

# Per-AZ private tables from day one — the split a NAT-per-AZ future needs,
# learned the hard way on the main VPC (nat-instance module docs).
resource "aws_route_table" "private" {
  for_each = local.az_index

  vpc_id = aws_vpc.main.id
  tags   = merge(local.base_tags, { Name = "hosted-private-${each.key}" })
}

resource "aws_route_table_association" "private" {
  for_each = local.az_index

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

# --- Egress: our own NAT, AZ-a to start (§3.1) --------------------------

module "nat" {
  source = "../nat-instance"

  env       = var.env
  name      = "hosted-nat-${local.az_names[var.azs[0]]}"
  az        = local.az_names[var.azs[0]]
  vpc_id    = aws_vpc.main.id
  subnet_id = aws_subnet.public[var.azs[0]].id
  vpc_cidr  = aws_vpc.main.cidr_block

  instance_type    = var.nat_instance_type
  alarm_topic_arns = var.nat_alarm_topic_arns
  tags             = local.base_tags
}

resource "aws_route" "private_nat" {
  for_each = local.az_index

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.nat.network_interface_id
}

# --- Peering: main VPC only, no edge routing (network_allocation §5) ----

resource "aws_vpc_peering_connection" "main" {
  vpc_id      = aws_vpc.main.id
  peer_vpc_id = var.main_vpc_id
  auto_accept = true

  tags = merge(local.base_tags, { Name = "hosted-fleet to main" })
}

resource "aws_route" "private_to_main" {
  for_each = local.az_index

  route_table_id            = aws_route_table.private[each.key].id
  destination_cidr_block    = var.main_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.main.id
}

resource "aws_route" "main_to_fleet" {
  count = length(var.main_route_table_ids)

  route_table_id            = var.main_route_table_ids[count.index]
  destination_cidr_block    = aws_vpc.main.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.main.id
}

# --- The workload SG: deny-all inbound, no per-mode exception (§8) ------

resource "aws_security_group" "node" {
  name        = "hosted-node"
  description = "Hosted nodes - no inbound in any transport mode; the CLI dials out"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.base_tags, { Name = "Hosted node" })
}

# --- ECS: the agent we did not write (hosted_nodes.md §6) ---------------

resource "aws_ecs_cluster" "hosted" {
  name = "meandr-hosted"
  tags = merge(local.base_tags, { Name = "Hosted fleet" })
}

# Instance role: ECS agent registration + SSM (log snapshots ride
# RunCommand). Nothing more — a bridge container cannot reach IMDS
# (hop limit 1), and the role stays minimal anyway.
resource "aws_iam_role" "node" {
  name = "hosted-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.base_tags
}

resource "aws_iam_role_policy_attachment" "node_ecs" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name = "hosted-node"
  role = aws_iam_role.node.name
}

# One SHARED task-execution role: assumed by the ECS agent, never exposed
# to the workload — with no task role assigned, the customer's container
# holds no AWS credentials at all (hosted_nodes.md §6).
resource "aws_iam_role" "task_execution" {
  name = "hosted-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.base_tags
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "read-hosted-secrets"
  role = aws_iam_role.task_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "HostedNodeParameters"
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/meandr/hosted/*"
    }]
  })
}

# --- Launch templates: one per arch -------------------------------------

# Stock ECS-optimized AL2023, resolved per arch. The data source pins the
# id in state — a bump is a deliberate apply, never a silent drift.
data "aws_ssm_parameter" "ecs_ami" {
  for_each = { arm64 = "arm64", amd64 = "x86_64" }

  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/${each.value == "x86_64" ? "" : "arm64/"}recommended/image_id"
}

locals {
  # Cluster join + agent headroom; per-tenant attributes are applied by
  # BE via ecs:PutAttributes after registration, not baked here. The
  # daemon.json caps keep a chatty MCP from a disk-full outage (§8.2).
  user_data = base64encode(<<-EOF
    #!/bin/bash
    cat > /etc/docker/daemon.json <<'JSON'
    {"log-driver":"json-file","log-opts":{"max-size":"20m","max-file":"3"}}
    JSON
    systemctl restart docker
    {
      echo "ECS_CLUSTER=${aws_ecs_cluster.hosted.name}"
      echo "ECS_RESERVED_MEMORY=${var.reserved_memory_mib}"
      echo "ECS_ENGINE_TASK_CLEANUP_WAIT_DURATION=3h"
    } >> /etc/ecs/ecs.config
  EOF
  )
}

resource "aws_launch_template" "node" {
  for_each = data.aws_ssm_parameter.ecs_ami

  name     = "hosted-node-${each.key}"
  image_id = each.value.value

  iam_instance_profile { arn = aws_iam_instance_profile.node.arn }
  vpc_security_group_ids = [aws_security_group.node.id]

  user_data = local.user_data

  # Standard credits hard-cap a shared rung's cost at its instance price;
  # T4g/T3a default to unlimited (§5). Harmless on c/m/r.
  credit_specification { cpu_credits = "standard" }

  # Hop limit 1: the ECS agent lives on the host namespace and is fine;
  # bridge containers are one hop away and get nothing (§7.1).
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  monitoring { enabled = false }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.base_tags, { Name = "hosted-node" })
  }
}

# Free (no hourly, no per-GB) — and ECR layer blobs are served FROM S3, so
# this takes the bulk of image-pull bytes off the NAT path.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]

  tags = merge(local.base_tags, { Name = "Hosted fleet S3" })
}
