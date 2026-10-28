# The gateway (product/hosted_models.md §5): one task in the zone of its
# queue's node, dialed by every region's hosted machines under a name of its
# own, since every region's svc.<zone> shares one name and a VPC takes one.

locals {
  gateway_name = "meandr-embed"
  gateway_port = 8446
  gateway_zone = "models.${var.internal_dns_zone.name}"
  cert_name    = "embed.${var.internal_dns_zone.name}"
  zone_a       = var.subnet_ids[0]
  meandr_env   = { staging = "stg", production = "prd" }[var.env]
  gateway_tags = merge(var.tags, { "meandr:role" = "embed-gateway" })

  # Every plane is a Valkey of ours: one AUTH token, one client keypair.
  plane_secrets = merge([for plane in ["QUEUE", "CONFIG_READER", "EVENT_WRITER"] : {
    "MEANDR_REDIS_${plane}_PASSWORD"    = var.redis.auth_secret_arn
    "MEANDR_REDIS_${plane}_CA_CERT"     = "${var.redis.client_secret_arn}:ca_crt::"
    "MEANDR_REDIS_${plane}_CLIENT_CERT" = "${var.redis.client_secret_arn}:client_crt::"
    "MEANDR_REDIS_${plane}_CLIENT_KEY"  = "${var.redis.client_secret_arn}:client_key::"
  }]...)
}

data "aws_subnet" "zone_a" {
  id = local.zone_a
}

module "cluster" {
  source = "../ecs-cluster"

  name = local.gateway_name
  tags = local.gateway_tags
}

# --- Network -------------------------------------------------------------

resource "aws_security_group" "gateway" {
  name_prefix = "meandr-embed-gw-"
  description = "Embedding gateway - hosted machines agents only"
  vpc_id      = var.vpc_id

  tags = merge(local.gateway_tags, { Name = "meandr-embed-gateway" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "agents" {
  for_each = toset(var.machines.cidrs)

  security_group_id = aws_security_group.gateway.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = local.gateway_port
  to_port           = local.gateway_port
  description       = "Hosted machines agents, over the peering"
}

resource "aws_vpc_security_group_egress_rule" "gateway" {
  security_group_id = aws_security_group.gateway.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Model nodes, Valkey, STS and CloudWatch"
}

# The roots associate both regions' hosted VPCs with this zone.
resource "aws_service_discovery_private_dns_namespace" "gateway" {
  name = local.gateway_zone
  vpc  = var.vpc_id

  tags = merge(local.gateway_tags, { Name = "Embedding gateway discovery" })
}

resource "aws_service_discovery_service" "gateway" {
  name = "embed"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.gateway.id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  tags = merge(local.gateway_tags, { Name = "Embedding gateway" })
}

# --- Queue ---------------------------------------------------------------

# Targeted, so no other instance in the zone can take it.
resource "aws_ec2_capacity_reservation" "queue" {
  instance_type           = "t4g.micro"
  instance_platform       = "Linux/UNIX"
  availability_zone       = data.aws_subnet.zone_a.availability_zone
  instance_count          = 1
  end_date_type           = "unlimited"
  instance_match_criteria = "targeted"

  tags = merge(local.gateway_tags, { Name = "meandr-embed-valkey" })
}

# Alone and unpersisted: the apps' stores can rebuild all it holds. Only
# keys with a TTL are evicted, so results go first and the queue never.
module "queue" {
  source = "../valkey-node"

  fleet                   = "embed"
  node                    = "${var.region_code}a"
  name                    = "meandr-embed-valkey-${var.region_code}a"
  role                    = "master"
  standalone              = true
  run_sentinel            = false
  instance_type           = "t4g.micro"
  capacity_reservation_id = aws_ec2_capacity_reservation.queue.id

  valkey_version       = var.valkey.version
  valkey_source_bucket = var.valkey.source_bucket
  valkey_source_sha256 = filesha256(var.valkey.source_path)
  auth_secret_arn      = var.redis.auth_secret_arn
  tls_secret_arn       = var.redis.node_secret_arn

  maxmemory_policy = "volatile-ttl"

  vpc_id        = var.vpc_id
  subnet_id     = local.zone_a
  client_cidrs  = [data.aws_subnet.zone_a.cidr_block]
  dns_zone_id   = var.internal_dns_zone.id
  dns_zone_name = var.internal_dns_zone.name

  tags = local.gateway_tags
}

# --- Identity ------------------------------------------------------------

resource "aws_iam_role" "gateway" {
  name = "meandr-embed-gateway-${var.env}-${local.region}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.gateway_tags, { Name = "meandr-embed-gateway" })
}

# The nodes from their groups, and the lanes' time for the GPU's alarms. No
# model outside our own nodes: apps' text goes to no third party. Proofs need
# no grant: STS answers the URL the machine signed.
resource "aws_iam_role_policy" "gateway" {
  name = "embed-gateway"
  role = aws_iam_role.gateway.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["autoscaling:DescribeAutoScalingGroups", "ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Effect    = "Allow"
        Action    = "cloudwatch:PutMetricData"
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = "Meandr/Embed" } }
      },
    ]
  })
}

resource "aws_iam_role_policy" "gateway_secrets" {
  name = "secrets-access"
  role = module.cluster.execution_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = [var.tls_secret_arn, var.redis.auth_secret_arn, var.redis.client_secret_arn]
    }]
  })
}

# --- Service -------------------------------------------------------------

module "gateway" {
  source = "../ecs-fargate-service"

  name               = local.gateway_name
  cluster_arn        = module.cluster.cluster_arn
  execution_role_arn = module.cluster.execution_role_arn
  task_role_arn      = aws_iam_role.gateway.arn

  image          = var.gateway.image
  container_port = local.gateway_port
  inject_rds_ca  = false

  cpu    = 256
  memory = 512

  environment = {
    MEANDR_ENV                                = local.meandr_env
    MEANDR_LOG_LEVEL                          = var.gateway.log_level
    AWS_REGION                                = local.region
    GOMEMLIMIT                                = "400MiB"
    MEANDR_EMBED_ACCOUNT                      = local.account
    MEANDR_EMBED_NAME                         = local.cert_name
    MEANDR_EMBED_MACHINE_REGIONS              = join(",", var.machines.regions)
    MEANDR_EMBED_LISTEN                       = ":${local.gateway_port}"
    MEANDR_EMBED_CPU_GROUP                    = local.cpu ? local.cpu_name : ""
    MEANDR_EMBED_PRIMARY_GROUP                = local.primary_name
    MEANDR_EMBED_FALLBACK_GROUP               = local.fallback_name
    MEANDR_EMBED_PEER_REGIONS                 = join(",", var.peer_regions)
    MEANDR_REDIS_QUEUE_ADDR                   = "${module.queue.hostname}:6379"
    MEANDR_REDIS_QUEUE_USE_TLS                = "true"
    MEANDR_REDIS_CONFIG_READER_USE_TLS        = "true"
    MEANDR_REDIS_CONFIG_READER_SENTINEL_ADDRS = join(",", var.redis.config.sentinel_addrs)
    MEANDR_REDIS_CONFIG_READER_MASTER_NAME    = var.redis.config.master
    MEANDR_REDIS_CONFIG_READER_PREFER_REPLICA = "true"
    MEANDR_REDIS_EVENT_WRITER_USE_TLS         = "true"
    MEANDR_REDIS_EVENT_WRITER_SENTINEL_ADDRS  = join(",", var.redis.events.sentinel_addrs)
    MEANDR_REDIS_EVENT_WRITER_MASTER_NAME     = var.redis.events.master
  }
  secrets = merge(local.plane_secrets, {
    MEANDR_EMBED_TLS_CERT = "${var.tls_secret_arn}:embed_crt::"
    MEANDR_EMBED_TLS_KEY  = "${var.tls_secret_arn}:embed_key::"
  })

  subnets              = [local.zone_a]
  security_group_ids   = [aws_security_group.gateway.id]
  service_registry_arn = aws_service_discovery_service.gateway.arn

  # The health listener answers on loopback only (cmd/meandr-embed).
  container_health_check = {
    command     = ["CMD", "/busybox", "wget", "-q", "--spider", "http://127.0.0.1:8447/healthz"]
    interval    = 30
    timeout     = 5
    retries     = 3
    startPeriod = 15
  }

  # One gateway, stopped before its replacement starts: two at once would
  # each drop the other's work as they pop it (hosted_models.md §8).
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  # Calls in hand 20 s, answers sent, connections closed, usage flushed.
  stop_timeout = 45

  desired_count          = 1
  enable_autoscaling     = false
  enable_execute_command = false

  log_group_name     = "/aws/ecs/meandr-embed"
  log_retention_days = var.gateway.log_retention_days
  region             = local.region

  tags = local.gateway_tags
}
