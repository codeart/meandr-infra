# meandr-api orchestrator — composes the building-block modules into the full
# Rails BE stack in a region: RDS + writer Valkey + reader Valkey + ACM cert +
# ALB + ECS cluster + puma service + jobs service + migrate task + IAM + DNS.
#
# Caller provides VPC inputs + per-env sizing. Module owns everything else.

# --- Account / region guard ---------------------------------------------

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

# --- Public DNS zone (in Shared account; used for cert + public record) -

data "aws_route53_zone" "public" {
  provider     = aws.dns
  name         = var.dns_zone_name
  private_zone = false
}

# --- Locals -------------------------------------------------------------

locals {
  region = data.aws_region.current.name
  image  = "${var.ecr_registry}/${var.image_repository}:${var.image_tag}"

  # 3-letter MEANDR_ENV per project_redis_topology convention.
  meandr_env = {
    staging    = "stg"
    production = "prd"
  }[var.env]

  db_name = "meandr_${var.env}"

  base_tags = merge({
    "meandr:env"        = var.env
    "meandr:app"        = "meandr-api"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }, var.extra_tags)

  # Shared container env. Every service / task uses the same set; the Rails
  # CMD chooses what to read.
  #
  # REDIS_READER_URL — `rediss://` (TLS) — reader is GD-replicated, always TLS-on.
  # REDIS_WRITER_URL — `rediss://` (TLS) — writer is per-region; only present
  #   when meandr-mcp is deployed in this region. Until then the env var is
  #   omitted and BE must tolerate its absence.
  app_environment = merge({
    RAILS_ENV                = var.env
    MEANDR_ENV               = local.meandr_env
    AWS_REGION               = local.region
    RAILS_LOG_TO_STDOUT      = "true"
    RAILS_SERVE_STATIC_FILES = "true"

    DATABASE_HOST = "pg.${var.internal_dns_zone_name}"
    DATABASE_PORT = "5432"
    DATABASE_NAME = local.db_name

    REDIS_READER_URL = "rediss://${var.reader_internal_dns_name}:6379"
    }, var.writer_internal_dns_name != null ? {
    REDIS_WRITER_URL = "rediss://${var.writer_internal_dns_name}:6379"
  } : {})

  app_secrets = {
    DATABASE_USERNAME = "${module.rds.secret_arn}:username::"
    DATABASE_PASSWORD = "${module.rds.secret_arn}:password::"
    SECRET_KEY_BASE   = aws_secretsmanager_secret.secret_key_base.arn
  }
}

# --- RDS Postgres -------------------------------------------------------

module "rds" {
  source = "../rds-postgres"

  name           = "meandr-api"
  db_name        = local.db_name
  engine_version = "18.4"

  instance_class           = var.db_instance_class
  allocated_storage_gb     = var.db_allocated_storage_gb
  max_allocated_storage_gb = var.db_max_allocated_storage_gb

  multi_az              = var.db_multi_az
  backup_retention_days = var.db_backup_retention_days
  deletion_protection   = var.db_deletion_protection
  skip_final_snapshot   = var.env != "production"

  vpc_id                 = var.vpc_id
  vpc_cidr_block         = var.vpc_cidr_block
  private_subnet_ids     = var.private_subnet_ids
  internal_dns_zone_id   = var.internal_dns_zone_id
  internal_dns_zone_name = var.internal_dns_zone_name

  secret_name = "meandr/db/${var.env}/master"

  tags = local.base_tags
}

# --- ACM cert (cross-account R53 validation) ----------------------------

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

# --- ALB ----------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "meandr-alb"
  description = "Public ingress for meandr-api ALB"
  vpc_id      = var.vpc_id

  tags = merge(local.base_tags, { Name = "Main ALB SG" })
}

resource "aws_security_group_rule" "alb_ingress_443" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "HTTPS from anywhere"
}

resource "aws_security_group_rule" "alb_ingress_80" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "HTTP from anywhere - redirects to HTTPS"
}

resource "aws_security_group_rule" "alb_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "To ECS tasks in private subnets"
}

resource "aws_lb" "main" {
  name               = "meandr-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false
  drop_invalid_header_fields = true

  tags = merge(local.base_tags, { Name = "Main ALB" })
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = module.cert.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }

  tags = merge(local.base_tags, { Name = "HTTPS Listener" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = merge(local.base_tags, { Name = "HTTP redirect listener" })
}

# --- ECS cluster + shared IAM -------------------------------------------

module "cluster" {
  source = "../ecs-cluster"

  name               = "meandr-api"
  log_retention_days = var.log_retention_days
  tags               = local.base_tags
}

# Execution role gets Secrets Manager read on the specific ARNs we inject.
resource "aws_iam_role_policy" "execution_secrets" {
  name = "secrets-access"
  role = module.cluster.execution_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "secretsmanager:GetSecretValue"
      Resource = [
        module.rds.secret_arn,
        aws_secretsmanager_secret.secret_key_base.arn,
      ]
    }]
  })
}

# Task role — the runtime identity Rails code runs as.
resource "aws_iam_role" "task" {
  name = "meandr-api-task-${var.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.base_tags, { Name = "meandr-api task role" })
}

resource "aws_iam_role_policy" "task_tenant_secrets" {
  name = "tenant-secrets"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecret",
          "secretsmanager:DeleteSecret",
          "secretsmanager:TagResource",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "arn:aws:secretsmanager:${local.region}:${var.account_id}:secret:meandr/tenants/*"
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:ListSecrets"
        Resource = "*"
      },
    ]
  })
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
          "cloudwatch:namespace" = ["meandr/api"]
        }
      }
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

# --- SECRET_KEY_BASE secret --------------------------------------------

resource "random_password" "secret_key_base" {
  length  = 128
  special = false
}

resource "aws_secretsmanager_secret" "secret_key_base" {
  name        = "meandr/api/${var.env}/secret-key-base"
  description = "Rails SECRET_KEY_BASE for meandr-api ${var.env}. Rotating invalidates sessions; rotate intentionally."

  tags = merge(local.base_tags, { Name = "meandr-api SECRET_KEY_BASE" })
}

resource "aws_secretsmanager_secret_version" "secret_key_base" {
  secret_id     = aws_secretsmanager_secret.secret_key_base.id
  secret_string = random_password.secret_key_base.result

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# --- Security groups for tasks ------------------------------------------

# Puma tasks accept traffic only from the ALB SG.
resource "aws_security_group" "puma" {
  name        = "meandr-api-puma"
  description = "Puma tasks - accepts traffic from ALB only"
  vpc_id      = var.vpc_id

  tags = merge(local.base_tags, { Name = "meandr-api-puma SG" })
}

resource "aws_security_group_rule" "puma_ingress_from_alb" {
  type                     = "ingress"
  security_group_id        = aws_security_group.puma.id
  source_security_group_id = aws_security_group.alb.id
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  description              = "From ALB SG"
}

resource "aws_security_group_rule" "puma_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.puma.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound"
}

# Workers (jobs + migrate) — no ingress, egress only.
resource "aws_security_group" "worker" {
  name        = "meandr-api-worker"
  description = "Worker tasks (jobs, migrate) - no ingress"
  vpc_id      = var.vpc_id

  tags = merge(local.base_tags, { Name = "meandr-api worker SG" })
}

resource "aws_security_group_rule" "worker_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.worker.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound"
}

# --- Puma target group + listener rule ----------------------------------

resource "aws_lb_target_group" "puma" {
  name        = "meandr-api-puma"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    path                = "/up" # Rails 7.1+ built-in
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = merge(local.base_tags, { Name = "meandr-api-puma TG" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener_rule" "puma" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  condition {
    host_header {
      values = [var.hostname]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.puma.arn
  }

  tags = merge(local.base_tags, { Name = "meandr-api-puma listener rule" })
}

# --- Puma service (Rails web) ------------------------------------------

module "puma" {
  source = "../ecs-fargate-service"

  name               = "meandr-api-puma"
  cluster_arn        = module.cluster.cluster_arn
  execution_role_arn = module.cluster.execution_role_arn
  task_role_arn      = aws_iam_role.task.arn

  image          = local.image
  command        = ["bundle", "exec", "puma", "-C", "config/puma.rb"]
  container_port = 3000

  cpu    = var.puma.cpu
  memory = var.puma.memory

  environment = local.app_environment
  secrets     = local.app_secrets

  subnets            = var.private_subnet_ids
  security_group_ids = [aws_security_group.puma.id]

  target_group_arn = aws_lb_target_group.puma.arn

  desired_count          = var.puma.desired_count
  min_replicas           = var.puma.min_replicas
  max_replicas           = var.puma.max_replicas
  target_cpu_utilization = var.puma.target_cpu_utilization

  log_group_name     = "/aws/ecs/meandr-api-puma"
  log_retention_days = var.log_retention_days
  region             = local.region

  tags = merge(local.base_tags, { "meandr:role" = "puma" })

  depends_on = [aws_lb_listener_rule.puma]
}

# --- Jobs service (Good Job) -------------------------------------------

module "jobs" {
  source = "../ecs-fargate-service"

  name               = "meandr-api-jobs"
  cluster_arn        = module.cluster.cluster_arn
  execution_role_arn = module.cluster.execution_role_arn
  task_role_arn      = aws_iam_role.task.arn

  image   = local.image
  command = ["bundle", "exec", "good_job", "start"]

  cpu    = var.jobs.cpu
  memory = var.jobs.memory

  environment = local.app_environment
  secrets     = local.app_secrets

  container_health_check = {
    command     = ["CMD-SHELL", "pgrep -f good_job || exit 1"]
    interval    = 30
    timeout     = 5
    retries     = 3
    startPeriod = 60
  }

  subnets            = var.private_subnet_ids
  security_group_ids = [aws_security_group.worker.id]

  target_group_arn = null

  desired_count          = var.jobs.desired_count
  min_replicas           = var.jobs.min_replicas
  max_replicas           = var.jobs.max_replicas
  target_cpu_utilization = var.jobs.target_cpu_utilization

  log_group_name     = "/aws/ecs/meandr-api-jobs"
  log_retention_days = var.log_retention_days
  region             = local.region

  tags = merge(local.base_tags, { "meandr:role" = "jobs" })
}

# --- Migrate one-off task ----------------------------------------------

module "migrate" {
  source = "../ecs-oneoff-task"

  name               = "meandr-api-migrate"
  execution_role_arn = module.cluster.execution_role_arn
  task_role_arn      = aws_iam_role.task.arn

  image   = local.image
  command = ["bundle", "exec", "rails", "db:migrate"]

  cpu    = var.migrate.cpu
  memory = var.migrate.memory

  environment = local.app_environment
  secrets     = local.app_secrets

  log_group_name     = "/aws/ecs/meandr-api-migrate"
  log_retention_days = var.log_retention_days
  region             = local.region

  tags = merge(local.base_tags, { "meandr:role" = "migrate" })
}

# --- Public DNS record --------------------------------------------------

resource "aws_route53_record" "public" {
  provider = aws.dns

  zone_id = data.aws_route53_zone.public.zone_id
  name    = var.hostname
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
