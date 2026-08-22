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

    # Cred-store wiring. Empty values are harmless — Rails treats them
    # as "cred-store not configured here" and skips the encrypt path.
    # See docs/credential_store.md for the BE-side responsibilities.
    MEANDR_CRED_TABLE_NAME    = var.creds_table_name
    MEANDR_CRED_KMS_KEY_ALIAS = var.cred_encryption_key_alias

    # Cross-account role for ACME DNS-01 challenge writes; the zones live
    # in the Shared account. Meandr::Acme reads this LAZILY, so an empty
    # value only fails an actual certificate order, never boot.
    MEANDR_ACME_DNS_ROLE_ARN = var.acme_dns_role_arn
  }

  app_secrets = merge({
    MEANDR_DATABASE_URL = "${module.rds.secret_arn}:url::"

    RAILS_MASTER_KEY = aws_secretsmanager_secret.rails_master_key.arn

    MEANDR_ENC_PRIMARY_KEY         = "${aws_secretsmanager_secret.encryption.arn}:primary_key::"
    MEANDR_ENC_DETERMINISTIC_KEY   = "${aws_secretsmanager_secret.encryption.arn}:deterministic_key::"
    MEANDR_ENC_KEY_DERIVATION_SALT = "${aws_secretsmanager_secret.encryption.arn}:key_derivation_salt::"

    MEANDR_OPS_USER     = "${aws_secretsmanager_secret.ops.arn}:user::"
    MEANDR_OPS_PASSWORD = "${aws_secretsmanager_secret.ops.arn}:password::"
    }, var.redis_auth_secret_arn == "" ? {} : {
    # Same token used for config-stream + event-stream + api-redis. Rails
    # reads from MEANDR_REDIS_PASSWORD at boot and threads into all three
    # client constructions.
    MEANDR_REDIS_PASSWORD = var.redis_auth_secret_arn
  })
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

  engine_version = "9.1"
  node_type      = var.api_redis_node_type

  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  auth_token = var.redis_auth_token

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
  engine_version = "18.6"

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
      Resource = compact([
        module.rds.secret_arn,
        aws_secretsmanager_secret.rails_master_key.arn,
        aws_secretsmanager_secret.encryption.arn,
        aws_secretsmanager_secret.ops.arn,
        var.redis_auth_secret_arn,
      ])
    }]
  })
}

# Task roles — the runtime identities Rails code runs as.
#
# `task`      — puma, ingest, migrate.
# `task_acme` — jobs, and jobs alone. Everything `task` has, plus the
#               three ACME grants below (acme-dns-assume, acme-account,
#               cert-write) and catalog DDL. Named for the first thing
#               that made it different, not the only one.
#
# Split because certificate issuance must not be reachable from a
# request-serving process: on one role, an RCE or SSRF in puma could
# PutSecretValue a certificate whose private key the attacker holds, and
# the proxy would serve it to every customer on that apex.
#
# The shared grants are managed policies rather than inline so each is
# written once and ATTACHED to both roles explicitly — every grant is a
# readable line, nothing is computed.
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

resource "aws_iam_role" "task_acme" {
  name = "meandr-api-acme-${var.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.base_tags, { Name = "meandr-api ACME task role" })
}

resource "aws_iam_policy" "tenant_secrets" {
  name = "meandr-api-tenant-secrets-${var.env}"

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

resource "aws_iam_role_policy_attachment" "task_tenant_secrets" {
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.tenant_secrets.arn
}

resource "aws_iam_role_policy_attachment" "acme_tenant_secrets" {
  role       = aws_iam_role.task_acme.name
  policy_arn = aws_iam_policy.tenant_secrets.arn
}

# --- Certificate issuance — JOBS ROLE ONLY ------------------------------
#
# The whole ACME chain lives here and nowhere else: assume the Shared
# account's DNS role to answer the challenge, read the Let's Encrypt
# account key to sign with, write the issued cert where the proxy reads
# it. Inline on task_acme so it CANNOT be attached to another role by
# accident.
#
# In development the meandr-dev user holds the same three grants (see
# account-development/main.tf) — a human runs the same flow locally.

# Route 53 access itself lives on the role in the Shared account; this is
# only permission to assume it. Gated on the ARN so an env with no ACME
# wiring gets no policy rather than one naming an empty resource.
resource "aws_iam_role_policy" "acme_dns_assume" {
  count = var.acme_dns_role_arn == "" ? 0 : 1

  name = "acme-dns-assume"
  role = aws_iam_role.task_acme.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumeAcmeDnsRole"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = var.acme_dns_role_arn
    }]
  })
}

# The account key at meandr/acme/<env>/account. Read-only — registered
# and stored by hand; the app only signs with it. Env-scoped, so staging
# cannot read production's key.
resource "aws_iam_role_policy" "acme_account" {
  name = "acme-account"
  role = aws_iam_role.task_acme.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AcmeAccountRead"
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = "arn:aws:secretsmanager:${local.region}:${var.account_id}:secret:meandr/acme/${var.env}/*"
    }]
  })
}

# Where issued certs land: meandr/certs/<env>/<apex>, which the proxy
# reads on cold-miss handshakes (read-only, modules/meandr-mcp).
# CreateSecret on first issuance, PutSecretValue on renewal; GetSecretValue
# so a renewal can check the stored cert's expiry rather than reissuing
# blind. No DeleteSecret. Env-scoped.
resource "aws_iam_role_policy" "acme_cert_write" {
  name = "cert-write"
  role = aws_iam_role.task_acme.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "CertIssueAndRenew"
      Effect = "Allow"
      Action = [
        "secretsmanager:CreateSecret",
        "secretsmanager:PutSecretValue",
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:TagResource",
      ]
      Resource = "arn:aws:secretsmanager:${local.region}:${var.account_id}:secret:meandr/certs/${var.env}/*"
    }]
  })
}

# Cred-store: DynamoDB R/W on the cred table + KMS GenerateDataKey/Decrypt
# on the CMK + SM C/R/U on the dated-key path. Gated on the bool var so
# the policy is omitted entirely when cred-store isn't wired (e.g. envs
# where BE doesn't manage creds yet). Same pattern reason as the Redis
# AUTH IAM in meandr-mcp — count needs a known-at-plan-time bool.
resource "aws_iam_policy" "cred_store" {
  count = var.cred_store_enabled ? 1 : 0

  name = "meandr-api-cred-store-${var.env}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoCredTableReadWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable",
        ]
        Resource = var.creds_table_arn
      },
      {
        Sid    = "KMSCredEncryption"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = var.cred_encryption_key_arn
      },
    ]
  })
}

# Capture buckets. The split is deliberate and asymmetric — BE and the
# proxy each WRITE their own bucket and read the other's, so neither can
# corrupt what the other produces:
#
#   archive    BE writes (daily Parquet), BE + Athena read.
#              The proxy has no access at all.
#   payloads   the proxy writes (body segments); BE READS and RETAGS,
#              never writes.
#
# BE's two reasons to touch payloads:
#   - the dashboard's "show me the request" button, a ranged GET by ref;
#   - the cancellation flow, which retags an account's objects from `inf`
#     to `1d` so the bucket's own lifecycle does the deleting. That is
#     why PutObjectTagging is here and PutObject is not — retagging is
#     how you get S3 to delete at scale without enumerating, since
#     S3 Batch Operations has no native delete job type.
#
# ListBucket is not optional for Athena: it enumerates partitions before
# it scans.
resource "aws_iam_policy" "capture" {
  count = var.capture_enabled ? 1 : 0

  name = "meandr-api-capture-buckets-${var.env}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ArchiveReadWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectTagging",
          "s3:GetObject",
          "s3:GetObjectTagging",
          "s3:DeleteObject",
          "s3:ListBucket",
          # Athena reads this bucket AND writes its results here. It
          # calls GetBucketLocation before running anything and answers a
          # missing grant with "Unable to verify/create output bucket",
          # which reads as the bucket not existing. Large result sets go
          # up as multipart uploads, hence the other three.
          "s3:GetBucketLocation",
          "s3:AbortMultipartUpload",
          "s3:ListBucketMultipartUploads",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          var.archive_bucket_arn,
          "${var.archive_bucket_arn}/*",
        ]
      },
      {
        # NO PutObject. Bodies have exactly one writer, and it is not BE.
        Sid    = "S3PayloadsReadAndRetag"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectTagging",
          "s3:PutObjectTagging",
          "s3:ListBucket",
        ]
        Resource = [
          var.payloads_bucket_arn,
          "${var.payloads_bucket_arn}/*",
        ]
      },
      {
        Sid      = "KMSCaptureBuckets"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
        Resource = var.payload_encryption_key_arn
      },
    ]
  })
}

# Archive query API — Athena over the Parquet in the archive bucket
# (Meandr::Athena). S3 and KMS come from capture-buckets above; this adds
# the query engine and the catalog.
#
# READ-ONLY on the catalog. `rake archive:provision` creates the tables
# and needs DDL, granted separately to the jobs role alone
# (archive_provision below) so a request-serving process can never
# reshape a table under a live query. The database itself is a Terraform
# resource in the region stack.
resource "aws_iam_policy" "archive_query" {
  # Same gate as capture-buckets: querying an archive this environment
  # does not write is not a thing to grant.
  count = var.capture_enabled ? 1 : 0

  name = "meandr-api-archive-query-${var.env}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The default workgroup, because the client names none.
        Sid    = "AthenaQueryExecution"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:StopQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:GetQueryResultsStream",
          "athena:ListQueryExecutions",
          "athena:GetWorkGroup",
        ]
        Resource = "arn:aws:athena:${local.region}:${var.account_id}:workgroup/primary"
      },
      {
        Sid    = "GlueCatalogRead"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions",
        ]
        Resource = [
          "arn:aws:glue:${local.region}:${var.account_id}:catalog",
          "arn:aws:glue:${local.region}:${var.account_id}:database/meandr_${var.env}",
          "arn:aws:glue:${local.region}:${var.account_id}:table/meandr_${var.env}/*",
        ]
      },
    ]
  })
}

# Catalog DDL for `rake archive:provision` — JOBS ROLE ONLY.
#
# Split from archive_query so puma and ingest keep a read-only catalog:
# the risk that mattered was a REQUEST-SERVING process able to reshape
# tables under a live query, and jobs serves no requests.
#
# CREATE and UPDATE, never DELETE. Provisioning adds tables and widens
# them as the Rails models change; removing one is an operator action,
# so the blast radius of a bug in the rake task stops at a wrong column.
resource "aws_iam_policy" "archive_provision" {
  count = var.capture_enabled ? 1 : 0

  name = "meandr-api-archive-provision-${var.env}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "glue:CreateTable",
        "glue:UpdateTable",
        "glue:GetDatabase",
      ]
      # The catalog itself is required: Glue authorizes DDL against the
      # catalog resource before it reaches the database or table.
      Resource = [
        "arn:aws:glue:${local.region}:${var.account_id}:catalog",
        "arn:aws:glue:${local.region}:${var.account_id}:database/meandr_${var.env}",
        "arn:aws:glue:${local.region}:${var.account_id}:table/meandr_${var.env}/*",
      ]
    }]
  })
}

resource "aws_iam_policy" "cloudwatch_metrics" {
  name = "meandr-api-cloudwatch-metrics-${var.env}"

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

resource "aws_iam_policy" "ssm_exec" {
  name = "meandr-api-ssm-exec-${var.env}"

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

# --- Attachments — who gets what, one readable line each ----------------
#
# Both roles get every shared policy. task_acme additionally holds the
# three inline ACME grants and archive_provision — jobs is where every
# privileged, non-request-serving capability lands.

resource "aws_iam_role_policy_attachment" "task_cred_store" {
  count      = var.cred_store_enabled ? 1 : 0
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.cred_store[0].arn
}

resource "aws_iam_role_policy_attachment" "acme_cred_store" {
  count      = var.cred_store_enabled ? 1 : 0
  role       = aws_iam_role.task_acme.name
  policy_arn = aws_iam_policy.cred_store[0].arn
}

resource "aws_iam_role_policy_attachment" "task_capture" {
  count      = var.capture_enabled ? 1 : 0
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.capture[0].arn
}

resource "aws_iam_role_policy_attachment" "acme_capture" {
  count      = var.capture_enabled ? 1 : 0
  role       = aws_iam_role.task_acme.name
  policy_arn = aws_iam_policy.capture[0].arn
}

resource "aws_iam_role_policy_attachment" "task_archive_query" {
  count      = var.capture_enabled ? 1 : 0
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.archive_query[0].arn
}

resource "aws_iam_role_policy_attachment" "acme_archive_query" {
  count      = var.capture_enabled ? 1 : 0
  role       = aws_iam_role.task_acme.name
  policy_arn = aws_iam_policy.archive_query[0].arn
}

# No task_ counterpart, and that asymmetry is the point — see the policy.
resource "aws_iam_role_policy_attachment" "acme_archive_provision" {
  count      = var.capture_enabled ? 1 : 0
  role       = aws_iam_role.task_acme.name
  policy_arn = aws_iam_policy.archive_provision[0].arn
}

resource "aws_iam_role_policy_attachment" "task_cloudwatch_metrics" {
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.cloudwatch_metrics.arn
}

resource "aws_iam_role_policy_attachment" "acme_cloudwatch_metrics" {
  role       = aws_iam_role.task_acme.name
  policy_arn = aws_iam_policy.cloudwatch_metrics.arn
}

resource "aws_iam_role_policy_attachment" "task_ssm_exec" {
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.ssm_exec.arn
}

resource "aws_iam_role_policy_attachment" "acme_ssm_exec" {
  role       = aws_iam_role.task_acme.name
  policy_arn = aws_iam_policy.ssm_exec.arn
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
      values = concat([var.hostname], var.extra_hostnames)
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
    WEB_CONCURRENCY      = var.puma.concurrency
    RAILS_MAX_THREADS    = var.puma.threads
  })
  secrets = local.app_secrets

  # Container-level health check is distinct from the ALB target-group
  # check on /up (which gates request routing). Without this block ECS
  # reports the puma task as "Unknown" indefinitely, which makes the
  # cluster's healthy-vs-total widget useless. Same /up endpoint either
  # way — Rails 7.1+ built-in.
  #
  # startPeriod = 120s because Rails boot (config + eager loading +
  # connection pool warmup) routinely takes 60-90s on Fargate; the
  # period only suppresses failure counting, doesn't delay the first
  # check, so generous is safe.
  container_health_check = {
    command     = ["CMD-SHELL", "curl -fsS http://localhost:3000/up || exit 1"]
    interval    = 30
    timeout     = 5
    retries     = 3
    startPeriod = 120
  }

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

  # The ACME role, not the shared one — jobs is the only task that issues
  # certificates. puma, ingest and migrate stay on aws_iam_role.task.
  task_role_arn = aws_iam_role.task_acme.arn

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
  command = ["bundle", "exec", "bin/proxy-ingest", "start"]

  cpu    = var.ingest.cpu
  memory = var.ingest.memory

  # One AR connection per region reader thread (events + audit per
  # region) plus slack for the orchestrator and any initializer-time
  # connections. 5 covers up to ~2 regions on this single-replica
  # default; bump when adding more.
  environment = merge(local.app_environment, {
    MEANDR_DATABASE_POOL = "30"
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
    MEANDR_DATABASE_POOL = "5"
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

# Additional names on the same front — today the OAuth issuer host, which
# MCP clients resolve from the proxy's RFC 9728 metadata. Same ALB, same
# target group; the wildcard cert already covers *.meandr.com, so a name
# here needs a record and a listener condition, nothing more.
resource "aws_route53_record" "extra" {
  for_each = toset(var.extra_hostnames)
  provider = aws.dns

  zone_id = data.aws_route53_zone.public.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
