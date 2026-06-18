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

# Cross-variable invariant: MEANDR_MCP_REGIONS and MEANDR_REDIS_INGRESS_URLS
# are positionally paired; mismatched lengths would cause the BE-side
# zip to silently drop entries. Inline `validation` blocks can only see
# their own variable, so the check lives here.
resource "null_resource" "input_pairing_guard" {
  lifecycle {
    precondition {
      condition     = length(var.regions) == length(var.event_writer_endpoints)
      error_message = "regions and event_writer_endpoints must have the same length — they're positionally paired into MEANDR_MCP_REGIONS / MEANDR_REDIS_INGRESS_URLS."
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
  app_environment = {
    RAILS_ENV                = var.env
    RAILS_LOG_TO_STDOUT      = "true"
    RAILS_SERVE_STATIC_FILES = "true"

    # CloudWatch Logs doesn't render ANSI.
    NO_COLOR = "1"

    MEANDR_ENV = local.meandr_env
    AWS_REGION = local.region

    # MEANDR_MCP_REGIONS + MEANDR_REDIS_INGRESS_URLS are positionally
    # paired — BE zips them into [[region, url], ...] to know which
    # event-stream writer corresponds to which proxy region. Lengths
    # must match (enforced by the input_pairing_guard below).
    MEANDR_REDIS_EGRESS_URL   = "rediss://${var.config_writer_endpoint}:6379"
    MEANDR_MCP_REGIONS        = join(",", var.regions)
    MEANDR_REDIS_INGRESS_URLS = join(",", [for h in var.event_writer_endpoints : "rediss://${h}:6379"])

    # API's own Redis — ActionCable pub/sub today, future API-owned
    # persistent state (anything we need to keep that isn't worth a
    # Postgres table). Separate from the proxy planes by intent: those
    # are GD-replicated (egress) or per-region writer-only (ingress);
    # neither is appropriate for arbitrary API data.
    MEANDR_REDIS_URL = "rediss://${module.api_valkey.primary_endpoint_address}:6379"
  }

  app_secrets = {
    MEANDR_DATABASE_URL = "${module.rds.secret_arn}:url::"

    RAILS_MASTER_KEY = aws_secretsmanager_secret.rails_master_key.arn

    MEANDR_ENC_PRIMARY_KEY         = "${aws_secretsmanager_secret.encryption.arn}:primary_key::"
    MEANDR_ENC_DETERMINISTIC_KEY   = "${aws_secretsmanager_secret.encryption.arn}:deterministic_key::"
    MEANDR_ENC_KEY_DERIVATION_SALT = "${aws_secretsmanager_secret.encryption.arn}:key_derivation_salt::"

    MEANDR_OPS_USER     = "${aws_secretsmanager_secret.ops.arn}:user::"
    MEANDR_OPS_PASSWORD = "${aws_secretsmanager_secret.ops.arn}:password::"
  }
}

# --- API Redis (ActionCable + future API-owned persistent state) -------
#
# Single-node, no replication, no Multi-AZ — this is API-owned working
# storage, not customer-facing. ActionCable is the immediate consumer
# (per-subscription pub/sub for live introspect updates, etc.); future
# API-only persistent state can land here too. Separate from the proxy
# planes by intent: egress is GD-replicated (config), ingress is
# per-region writer-only (proxy → BE streams); neither is suitable for
# arbitrary API data.
#
# TLS-on for consistency with the other Valkeys. AT-rest encryption on
# since the cable subscription identifiers may surface internal IDs.

module "api_valkey" {
  source = "../elasticache-valkey"

  name        = "meandr-api-redis"
  description = "API-owned Redis: ActionCable + persistent state"

  engine_version = "8.1"
  node_type      = var.api_redis_node_type

  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  snapshot_retention_days = 1

  vpc_id             = var.vpc_id
  vpc_cidr_block     = var.vpc_cidr_block
  private_subnet_ids = var.private_subnet_ids

  tags = merge(local.base_tags, { "meandr:cluster" = "api" })
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
        aws_secretsmanager_secret.rails_master_key.arn,
        aws_secretsmanager_secret.encryption.arn,
        aws_secretsmanager_secret.ops.arn,
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

# --- RAILS_MASTER_KEY secret -------------------------------------------
#
# Rails 7+ encrypted credentials live in the BE repo at
# config/credentials/<env>.yml.enc; the matching key file
# config/credentials/<env>.key is gitignored. In production / staging we
# inject the .key contents as RAILS_MASTER_KEY and Rails decrypts the
# enc file at boot to populate Rails.application.credentials.
#
# Terraform creates the secret but never sets the value (operator
# populates it with `aws secretsmanager put-secret-value` once per env).
# A bootstrap placeholder is written so the ECS task can start; the real
# value overrides it out-of-band.

resource "aws_secretsmanager_secret" "rails_master_key" {
  name        = "meandr/api/${var.env}/rails-master-key"
  description = "Rails master key — decrypts config/credentials/${var.env}.yml.enc. Populate from config/credentials/${var.env}.key in the meandr-api repo."

  tags = merge(local.base_tags, { Name = "meandr-api RAILS_MASTER_KEY" })
}

resource "aws_secretsmanager_secret_version" "rails_master_key" {
  secret_id     = aws_secretsmanager_secret.rails_master_key.id
  secret_string = "POPULATE_FROM_CREDENTIALS_KEY_FILE"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# --- Active Record encryption keys --------------------------------------
#
# Rails 7+ `bin/rails db:encryption:init` generates three hex strings
# (16 bytes each). We replicate that with `random_id.hex`. Stored as one
# JSON secret with three keys so the ARN list stays compact.
#
# Rotating ANY of these invalidates all encrypted records — hence
# ignore_changes on the secret version. For production, generate values
# with `bin/rails db:encryption:init` and `put-secret-value` directly;
# Terraform won't overwrite.

resource "random_id" "enc_primary_key" {
  byte_length = 16
}

resource "random_id" "enc_deterministic_key" {
  byte_length = 16
}

resource "random_id" "enc_key_derivation_salt" {
  byte_length = 16
}

resource "aws_secretsmanager_secret" "encryption" {
  name        = "meandr/api/${var.env}/encryption"
  description = "Active Record encryption keys (primary, deterministic, salt). Rotation invalidates encrypted data."

  tags = merge(local.base_tags, { Name = "meandr-api encryption keys" })
}

resource "aws_secretsmanager_secret_version" "encryption" {
  secret_id = aws_secretsmanager_secret.encryption.id
  secret_string = jsonencode({
    primary_key         = random_id.enc_primary_key.hex
    deterministic_key   = random_id.enc_deterministic_key.hex
    key_derivation_salt = random_id.enc_key_derivation_salt.hex
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# --- Ops dashboards basic-auth ------------------------------------------
#
# HTTP basic auth credentials for Sidekiq::Web and GoodJob::Engine mounts
# (per Rails-side `config/initializers/ops_dashboards.rb`). Single secret
# with user + password JSON keys.

resource "random_password" "ops_password" {
  length  = 32
  special = false # avoid URL/header-quoting surprises in basic auth
}

resource "aws_secretsmanager_secret" "ops" {
  name        = "meandr/api/${var.env}/ops"
  description = "HTTP basic-auth credentials for the ops dashboards (Sidekiq::Web, GoodJob::Engine)."

  tags = merge(local.base_tags, { Name = "meandr-api ops basic auth" })
}

resource "aws_secretsmanager_secret_version" "ops" {
  secret_id = aws_secretsmanager_secret.ops.id
  secret_string = jsonencode({
    user     = "ops"
    password = random_password.ops_password.result
  })

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

  # Per-service DB pool sizing on top of the shared env. Puma's
  # WEB_CONCURRENCY × RAILS_MAX_THREADS sets the upper bound on
  # concurrent active connections from a single task; 15 covers the
  # worst case (1 × ~10-12 threads) with headroom for one-off Rake-y
  # work that grabs an extra connection.
  environment = merge(local.app_environment, {
    MEANDR_DATABASE_POOL = "15"
  })
  secrets = local.app_secrets

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

  # Jobs runs GOOD_JOB_MAX_THREADS workers in one process, each holding
  # an AR connection for the duration of its job. 30 = headroom for the
  # max worker pool plus the dispatcher loops and the audit walker's
  # short-burst connections (RedisSync::*Job fan-out).
  environment = merge(local.app_environment, {
    MEANDR_DATABASE_POOL = "30"
  })
  secrets = local.app_secrets

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

# --- Proxy-ingest service ----------------------------------------------

module "ingest" {
  source = "../ecs-fargate-service"

  name               = "meandr-api-ingest"
  cluster_arn        = module.cluster.cluster_arn
  execution_role_arn = module.cluster.execution_role_arn
  task_role_arn      = aws_iam_role.task.arn

  image   = local.image
  command = ["bundle", "exec", "bin/proxy-ingest"]

  cpu    = var.ingest.cpu
  memory = var.ingest.memory

  # One AR connection per region reader thread (events + audit per
  # region) plus slack for the orchestrator and any initializer-time
  # connections. 5 covers up to ~2 regions on this single-replica
  # default; bump when adding more.
  environment = merge(local.app_environment, {
    MEANDR_DATABASE_POOL = "5"
  })
  secrets = local.app_secrets

  # pgrep matches both the orchestrator parent and the per-region
  # children — a single hit means at least one process is alive.
  container_health_check = {
    command     = ["CMD-SHELL", "pgrep -f proxy-ingest || exit 1"]
    interval    = 30
    timeout     = 5
    retries     = 3
    startPeriod = 60
  }

  subnets            = var.private_subnet_ids
  security_group_ids = [aws_security_group.worker.id]

  target_group_arn = null

  desired_count      = var.ingest.desired_count
  enable_autoscaling = false

  log_group_name     = "/aws/ecs/meandr-api-ingest"
  log_retention_days = var.log_retention_days
  region             = local.region

  tags = merge(local.base_tags, { "meandr:role" = "ingest" })
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

  # Migrations run serially — one for the migration itself, one for
  # the boot-time schema_migrations check, one of headroom for any
  # initializer that touches AR at load. Wider than 3 is wasted; 1
  # is too tight (initializers reliably reach for a second connection).
  environment = merge(local.app_environment, {
    MEANDR_DATABASE_POOL = "3"
  })
  secrets = local.app_secrets

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
