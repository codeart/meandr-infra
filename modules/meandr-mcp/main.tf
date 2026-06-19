# meandr-mcp orchestrator — proxy stack for a region.
#
# Composes:
#   - Event-stream Valkey (per-region standalone, TLS-on for future AUTH)
#   - NLB in public subnets (TCP passthrough — proxy terminates TLS itself
#     once the BE-side cert pipeline lands; see variables.tf for status)
#   - ECS cluster + proxy service (desired_count overridable; 0 = idle)
#   - Wildcard DNS record `*.<dns_zone_name>` → NLB (zone resolved in the
#     Shared account; staging uses meandr.live, production uses meandr.io)
#
# Config-stream Valkey is NOT created here. The region-level caller creates
# it (since meandr-api needs it too), and passes the endpoint as input.

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

  meandr_env = {
    staging    = "stg"
    production = "prd"
  }[var.env]

  base_tags = merge({
    "meandr:env"        = var.env
    "meandr:app"        = "meandr-mcp"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }, var.extra_tags)

  # Proxy env vars — see meandr-mcp/internal/app/config.go for the full
  # set. Redis access uses ADDR + USE_TLS, NOT URL-shape. ConfigSource
  # MUST be `redis` (the default `static` looks for dev-tenant.json which
  # isn't in the distroless image).
  #
  # No MEANDR_TLS_* vars set — TLS termination is deferred (see variables.tf
  # comment). Proxy listens plain HTTP on :8080; NLB multiplexes both 80
  # and 443 onto that port.
  proxy_environment = {
    MEANDR_REGION    = local.region
    MEANDR_ENV       = local.meandr_env
    MEANDR_LOG_LEVEL = var.log_level

    # CloudWatch Logs doesn't render ANSI.
    NO_COLOR = "1"

    MEANDR_LISTEN_ADDR     = ":${var.proxy_port}"
    MEANDR_TLS_LISTEN_ADDR = ":${var.proxy_tls_port}"

    MEANDR_CONFIG_SOURCE = "redis"

    # Two Redis planes:
    #   CONFIG_READER → config-stream replica (config records + inbound XREAD)
    #   EVENT_WRITER  → event-stream primary  (outbound XADD + audit + SETNX dedup)
    # The proxy is read-only on the config-stream cluster (no XREADGROUP,
    # no XACK, no SETNX) — see the variable doc on config_reader_endpoint
    # for why the replica endpoint is correct. Both connect to AWS-
    # internal hostnames directly so the clusters' wildcard certs
    # verify cleanly.
    MEANDR_REDIS_CONFIG_READER_ADDR    = "${var.config_reader_endpoint}:6379"
    MEANDR_REDIS_CONFIG_READER_USE_TLS = "true"

    MEANDR_REDIS_EVENT_WRITER_ADDR    = "${module.event_stream.primary_endpoint_address}:6379"
    MEANDR_REDIS_EVENT_WRITER_USE_TLS = "true"
  }

  # Proxy task def secrets — keyed by env-var name, valueFrom is the SM
  # secret ARN. The Redis AUTH token reaches the proxy as two env vars
  # (one per plane) so the existing config.RedisEndpoint.Password field
  # is populated for each client without app-side glue. Same SM secret
  # behind both — single token across all three Redis planes.
  proxy_secrets = var.redis_auth_enabled ? {
    MEANDR_REDIS_CONFIG_READER_PASSWORD = var.redis_auth_secret_arn
    MEANDR_REDIS_EVENT_WRITER_PASSWORD  = var.redis_auth_secret_arn
  } : {}
}

# --- Event-stream Valkey (per-region, no replication) -----------------
#
# The event-stream half of the proxy/BE Redis topology: counters (rl:
# hash), outbound/audit streams, dedup locks. Per-region, never GD-
# replicated — each region has its own event cluster. Proxy writes
# everything here (so connects to the writer/primary endpoint); BE
# consumes the streams (also via the writer endpoint, because
# XREADGROUP requires a writable node).
#
# Both consumers dial the AWS-internal hostnames directly — no CNAME
# indirection — so the cluster's wildcard cert verifies cleanly.

module "event_stream" {
  source = "../elasticache-valkey"

  name        = "meandr-event-stream"
  description = "Event-stream Valkey - proxy writes counters/streams/locks, BE consumes streams"

  engine_version = "8.1"
  node_type      = var.event_stream_node_type

  num_cache_clusters         = var.event_stream_replicas
  automatic_failover_enabled = false
  multi_az_enabled           = false

  # TLS-on from day 1 — AUTH requires TLS-in-transit which can't be
  # enabled in-place after creation.
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  auth_token = var.redis_auth_token

  snapshot_retention_days = var.event_stream_snapshot_retention_days

  vpc_id             = var.vpc_id
  vpc_cidr_block     = var.vpc_cidr_block
  private_subnet_ids = var.private_subnet_ids

  tags = merge(local.base_tags, { "meandr:plane" = "event" })
}

# Local-module rename in state. The underlying AWS resource ID also changed
# (`meandr-writer` → `meandr-event-stream`), so this is a destroy/recreate,
# not a state-only move — `moved` here just keeps `terraform plan`'s diff
# tidy by addressing the old + new state nodes by the same logical name.
moved {
  from = module.writer_valkey
  to   = module.event_stream
}

# --- NLB (network load balancer) ---------------------------------------
#
# TCP load balancer (not HTTP/HTTPS) — the proxy terminates TLS itself
# (per the E2E-encryption product commitment). NLB just forwards bytes.
#
# Two TCP listeners:
#   :80  → proxy plain-HTTP TG  → proxy:proxy_port     (cleartext)
#   :443 → proxy TLS TG         → proxy:proxy_tls_port (TLS, terminated in proxy)
#
# The proxy serves both ports — one via NewHTTP, one via NewHTTPS with
# the cert.Cache wired. End-to-end encryption is preserved: bytes only
# decrypt in the proxy task, never at the NLB.
#
# Until the BE-side cert pipeline lands, HTTPS handshakes will fail at
# cert lookup (cert.Cache has no live Provider data). The routing shape
# is correct; the cert side is what's missing.

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

resource "aws_lb_target_group" "proxy_tls" {
  name        = "meandr-mcp-proxy-tls"
  port        = var.proxy_tls_port
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  # TCP probe on the TLS port — verifies the socket accepts connections.
  # A full TLS-protocol probe would require ACM/SNI awareness inside the
  # health check; the TCP-level signal is sufficient given ECS already
  # gates task health at the container level.
  health_check {
    enabled             = true
    protocol            = "TCP"
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = merge(local.base_tags, { Name = "MCP proxy TLS TG" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http_80" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.proxy.arn
  }

  tags = merge(local.base_tags, { Name = "MCP NLB TCP:80 listener" })
}

resource "aws_lb_listener" "http_443" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.proxy_tls.arn
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

# Execution role gets SM read on the proxy-side secrets we inject as task
# def `secrets` (env-vars-from-SM). Distinct from the task role above —
# task role is the runtime identity (proxy code), execution role is what
# ECS uses to *fetch* secrets at task launch and pass them as env vars.
resource "aws_iam_role_policy" "execution_secrets" {
  count = var.redis_auth_enabled ? 1 : 0

  name = "secrets-access"
  role = module.cluster.execution_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = [var.redis_auth_secret_arn]
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
  # name_prefix + create_before_destroy lets TF spin up a replacement SG
  # under a fresh generated name when an immutable field (description,
  # vpc_id) changes — the service swaps to the new SG ID, tasks roll,
  # then the old SG drops. Avoids the ENI-still-attached deadlock that
  # `name = "..."` causes (AWS rejects duplicate names per VPC).
  name_prefix = "meandr-mcp-proxy-"
  description = "Proxy tasks - accepts customer traffic on ${var.proxy_port} (plain HTTP) and ${var.proxy_tls_port} (TLS). NLB :80 and :443 forward to these respective ports."
  vpc_id      = var.vpc_id

  tags = merge(local.base_tags, { Name = "meandr-mcp-proxy SG" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "proxy_ingress_plain" {
  type              = "ingress"
  security_group_id = aws_security_group.proxy.id

  from_port   = var.proxy_port
  to_port     = var.proxy_port
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
  description = "Plain HTTP customer traffic via NLB :80 (client IP preserved when target_type=ip)"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "proxy_ingress_tls" {
  type              = "ingress"
  security_group_id = aws_security_group.proxy.id

  from_port   = var.proxy_tls_port
  to_port     = var.proxy_tls_port
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
  description = "TLS customer traffic via NLB :443 (proxy terminates TLS; client IP preserved when target_type=ip)"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "proxy_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.proxy.id

  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
  description = "All outbound (upstream MCP servers, Redis, Secrets Manager, ECR)"

  lifecycle {
    create_before_destroy = true
  }
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
  secrets     = local.proxy_secrets

  subnets            = var.private_subnet_ids
  security_group_ids = [aws_security_group.proxy.id]

  target_group_arn = aws_lb_target_group.proxy.arn
  extra_load_balancers = [
    {
      target_group_arn = aws_lb_target_group.proxy_tls.arn
      container_port   = var.proxy_tls_port
    },
  ]

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

# --- Wildcard DNS *.<dns_zone_name> → NLB ------------------------------

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
