# meandr-mcp orchestrator — proxy stack for a region.
#
# Composes:
#   - Writer Valkey (per-region standalone, TLS-on for future AUTH)
#   - ACM cert (*.meandr.io, cross-account R53 validation)
#   - NLB in public subnets (TCP passthrough — proxy terminates TLS itself)
#   - ECS cluster + proxy service (desired_count overridable; 0 = idle)
#   - Wildcard DNS record `*.meandr.io` → NLB
#
# Reader Valkey is NOT created here. The region-level caller creates it (since
# meandr-api needs it too), and passes the endpoint as input.

# --- Account guard ------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "null_resource" "account_guard" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.account_id
      error_message = "Account mismatch: expected ${var.account_id}, got ${data.aws_caller_identity.current.account_id}. Wrong AWS_PROFILE?"
    }
  }
}

# --- Public DNS zone (Shared account) -----------------------------------

data "aws_route53_zone" "public" {
  provider     = aws.dns
  name         = var.dns_zone_name
  private_zone = false
}

# --- Locals -------------------------------------------------------------

locals {
  region = data.aws_region.current.name
  image  = "${var.ecr_registry}/${var.image_repository}:${var.image_tag}"

  base_tags = merge({
    "meandr:env"        = var.env
    "meandr:app"        = "meandr-mcp"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }, var.extra_tags)

  # Proxy reads from reader Valkey (config + events) and writes to writer
  # Valkey (telemetry, dedup locks). Both TLS-on.
  proxy_environment = {
    MEANDR_REGION           = local.region
    MEANDR_ENV              = var.env == "staging" ? "stg" : "prd"
    MEANDR_REDIS_READER_URL = "rediss://${var.reader_internal_dns_name}:6379"
    MEANDR_REDIS_WRITER_URL = "rediss://${module.writer.internal_dns_name}:6379"
  }
}

# --- Writer Valkey (standalone, TLS-on, no replication) ----------------

module "writer" {
  source = "../elasticache-valkey"

  name        = "meandr-writer"
  description = "Writer Valkey - proxy writes telemetry + dedup locks here, BE consumes via streams"
  role        = "writer"

  engine_version = "8.1"
  node_type      = var.writer_node_type

  num_cache_clusters         = var.writer_replicas
  automatic_failover_enabled = false
  multi_az_enabled           = false

  # TLS-on from day 1 — production may add AUTH tokens later, and AUTH
  # requires TLS-in-transit which can't be enabled in-place after creation.
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  snapshot_retention_days = var.writer_snapshot_retention_days

  vpc_id                 = var.vpc_id
  vpc_cidr_block         = var.vpc_cidr_block
  private_subnet_ids     = var.private_subnet_ids
  internal_dns_zone_id   = var.internal_dns_zone_id
  internal_dns_zone_name = var.internal_dns_zone_name

  tags = merge(local.base_tags, { "meandr:role" = "writer" })
}

# --- ACM cert -----------------------------------------------------------

module "cert" {
  source = "../acm-cert"

  providers = {
    aws     = aws
    aws.dns = aws.dns
  }

  domain_name               = var.cert_domain
  subject_alternative_names = var.cert_subject_alternative_names
  dns_zone_name             = var.dns_zone_name

  tags = local.base_tags
}

# --- NLB (network load balancer) ---------------------------------------
#
# TCP load balancer (not HTTP/HTTPS) — the proxy terminates TLS itself per
# CLAUDE.md "TLS termination" note. NLB just forwards bytes. ALB would have
# to strip and re-establish TLS which loses information the proxy uses for
# client identification.

resource "aws_lb" "main" {
  name               = "meandr-mcp-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = var.public_subnet_ids

  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = true

  tags = merge(local.base_tags, { Name = "MCP NLB" })
}

resource "aws_lb_target_group" "proxy" {
  name        = "meandr-mcp-proxy"
  port        = var.proxy_port
  protocol    = "TCP"
  target_type = "ip" # Fargate awsvpc mode
  vpc_id      = var.vpc_id

  # TCP-level health check. The proxy listens on TLS so HTTP health check
  # won't work; TCP just verifies the socket is open. Real health is
  # better assessed at the ECS task health-check level.
  health_check {
    enabled             = true
    protocol            = "TCP"
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = merge(local.base_tags, { Name = "MCP proxy TG" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "tls" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.proxy.arn
  }

  tags = merge(local.base_tags, { Name = "MCP NLB TCP:443 listener" })
}

# --- ECS cluster + IAM --------------------------------------------------

module "cluster" {
  source = "../ecs-cluster"

  name               = "meandr-mcp"
  log_retention_days = var.log_retention_days
  tags               = local.base_tags
}

# Task role — proxy runtime identity. Minimal: CloudWatch metrics + SSM exec.
# Proxy reads config from Redis (no AWS SDK call for that); auth secrets are
# fetched via the execution role at task-start.
resource "aws_iam_role" "task" {
  name = "meandr-mcp-task-${var.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.base_tags, { Name = "meandr-mcp task role" })
}

resource "aws_iam_role_policy" "task_cloudwatch_metrics" {
  name = "cloudwatch-metrics"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "cloudwatch:PutMetricData"
      Resource = "*"
      Condition = {
        StringEquals = {
          "cloudwatch:namespace" = ["meandr/mcp"]
        }
      }
    }]
  })
}

# Proxy reads tenant outbound auth secrets at runtime (per CLAUDE.md "Credentials"
# section). Read-only on the meandr/tenants/* path; BE writes them.
resource "aws_iam_role_policy" "task_tenant_secrets" {
  name = "tenant-secrets-read"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = "arn:aws:secretsmanager:${local.region}:${var.account_id}:secret:meandr/tenants/*"
    }]
  })
}

resource "aws_iam_role_policy" "task_ssm_exec" {
  name = "ssm-exec"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

# --- Proxy security group ----------------------------------------------
#
# Proxy ENI accepts traffic from anywhere on the proxy_port (NLB passes the
# client's source IP through unchanged when target_type = ip + TCP).

resource "aws_security_group" "proxy" {
  name        = "meandr-mcp-proxy"
  description = "Proxy tasks - accepts TLS traffic on ${var.proxy_port}"
  vpc_id      = var.vpc_id

  tags = merge(local.base_tags, { Name = "meandr-mcp-proxy SG" })
}

resource "aws_security_group_rule" "proxy_ingress_tls" {
  type              = "ingress"
  security_group_id = aws_security_group.proxy.id

  from_port   = var.proxy_port
  to_port     = var.proxy_port
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
  description = "TLS ingress from NLB (which preserves client IP)"
}

resource "aws_security_group_rule" "proxy_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.proxy.id

  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
  description = "All outbound (upstream MCP servers, Redis, Secrets Manager, ECR)"
}

# --- Proxy service ------------------------------------------------------

module "proxy" {
  source = "../ecs-fargate-service"

  name               = "meandr-mcp-proxy"
  cluster_arn        = module.cluster.cluster_arn
  execution_role_arn = module.cluster.execution_role_arn
  task_role_arn      = aws_iam_role.task.arn

  image          = local.image
  container_port = var.proxy_port

  cpu    = var.proxy.cpu
  memory = var.proxy.memory

  environment = local.proxy_environment

  subnets            = var.private_subnet_ids
  security_group_ids = [aws_security_group.proxy.id]

  target_group_arn = aws_lb_target_group.proxy.arn

  desired_count          = var.proxy.desired_count
  enable_autoscaling     = var.proxy.desired_count > 0
  min_replicas           = var.proxy.min_replicas
  max_replicas           = var.proxy.max_replicas
  target_cpu_utilization = var.proxy.target_cpu_utilization

  log_group_name     = "/aws/ecs/meandr-mcp-proxy"
  log_retention_days = var.log_retention_days
  region             = local.region

  tags = merge(local.base_tags, { "meandr:role" = "proxy" })
}

# --- Wildcard DNS *.meandr.io → NLB ------------------------------------

resource "aws_route53_record" "wildcard" {
  provider = aws.dns

  zone_id = data.aws_route53_zone.public.zone_id
  name    = "*.${var.dns_zone_name}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
