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
  region = data.aws_region.current.region

  # Pull from THIS region's ECR replica, never the source registry: a
  # cross-region pull puts another region on the task-start path, which is
  # the dependency a second region exists to remove. shared/ecr.tf
  # replicates account-wide, so the copy is already there.
  ecr_registry = var.ecr_registry != "" ? var.ecr_registry : "${var.ecr_registry_account_id}.dkr.ecr.${local.region}.amazonaws.com"
  image        = "${local.ecr_registry}/${var.image_repository}:${var.image_tag}"

  meandr_env = {
    staging    = "stg"
    production = "prd"
  }[var.env]

  # OAuth issuer. NOT derived from dns_zone_name: that is the tenant
  # wildcard zone (*.meandr.io), and the authorization server lives on
  # BE's zone instead — putting it in the tenant namespace would mean
  # reserving a slug forever to stop a tenant serving metadata at the
  # issuer URL. The caller instantiates both modules and passes BE's
  # host explicitly.
  #
  # Empty until oauth_discovery_enabled, because advertising an issuer
  # BE does not serve yet is worse than advertising none: clients would
  # discover it, fail, and cache the failure.
  oauth_issuer = var.oauth_discovery_enabled ? "https://${var.oauth_issuer_host}" : ""

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
  proxy_environment = {
    MEANDR_REGION    = local.region
    MEANDR_ENV       = local.meandr_env
    MEANDR_LOG_LEVEL = var.log_level

    # CloudWatch Logs doesn't render ANSI.
    NO_COLOR = "1"

    MEANDR_LISTEN_ADDR     = ":${var.proxy_port}"
    MEANDR_TLS_LISTEN_ADDR = ":${var.proxy_tls_port}"

    # Single wildcard apex this proxy serves a cert for. Same apex as
    # the public DNS zone — by design the cert covers what DNS resolves
    # to. Proxy validates SNI matches exactly `<one-label>.<apex>` and
    # fetches the cert from SM at meandr/certs/<env-full>/<apex>.
    MEANDR_CERT_APEX = var.dns_zone_name

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

    MEANDR_REDIS_EVENT_WRITER_ADDR    = "${local.event_writer_host}:6379"
    MEANDR_REDIS_EVENT_WRITER_USE_TLS = "true"

    # Sentinel makes the ADDRs above a bootstrap fallback rather than the
    # source of truth: the client asks who the master is and follows a
    # failover instead of waiting out a DNS TTL.
    #
    # LOCAL sentinels only. Sentinel answers with a node HOSTNAME, so a
    # cross-region sentinel would name something this VPC cannot resolve —
    # the proxy only ever needs its own region on both planes.
    MEANDR_REDIS_CONFIG_READER_SENTINEL_ADDRS = join(",", var.config_sentinel_addrs)
    MEANDR_REDIS_CONFIG_READER_MASTER_NAME    = var.config_sentinel_master
    MEANDR_REDIS_EVENT_WRITER_SENTINEL_ADDRS  = join(",", var.event_sentinel_addrs)
    MEANDR_REDIS_EVENT_WRITER_MASTER_NAME     = var.event_sentinel_master

    # The proxy never writes config, so reads go to a replica and fall
    # back to the master when Sentinel reports none — a replica down for
    # maintenance degrades rather than fails. The event plane is writes,
    # so it takes the master and no such flag.
    MEANDR_REDIS_CONFIG_READER_PREFER_REPLICA = "true"

    # No *_CA_CERT_FILE here: the runtime image is distroless, so there is
    # no init container to write files. The PEMs arrive inline through
    # proxy_secrets below — see there for why that is not the same as
    # putting them in the task definition.

    # Cred-store wiring. Empty value = "no cred-store" — proxy's
    # cred-resolution falls back to the legacy per-server SM path
    # (via Server.cred_ref) until BE bumps cred_version. See
    # docs/credential_store.md §9 for the discriminator.
    MEANDR_CRED_TABLE_NAME = var.creds_table_name

    # Payload capture. Empty = capture disabled; the proxy stores
    # nothing and `log` policies degrade to metadata-only.
    MEANDR_CAPTURE_BUCKET = var.payloads_bucket

    # Required — the proxy refuses to boot without it (payloadcrypt has
    # no plaintext fallback).
    MEANDR_PAYLOAD_KMS_KEY_ALIAS = var.payload_encryption_key_alias

    MEANDR_SESSION_TTL = var.session_ttl

    # OAuth discovery. Empty = dark: no WWW-Authenticate hint on 401s
    # and the RFC 9728 well-known route 404s.
    MEANDR_OAUTH_ISSUER = local.oauth_issuer
  }

  # Proxy task def secrets — keyed by env-var name, valueFrom is the SM
  # secret ARN. The Redis AUTH token reaches the proxy as two env vars
  # (one per plane) so the existing config.RedisEndpoint.Password field
  # is populated for each client without app-side glue. Same SM secret
  # behind both — single token across all three Redis planes.
  proxy_secrets = merge(
    # Not a secret — injected this way because ECS `secrets` resolves an
    # SSM parameter by ARN, which keeps one writer for a value both the
    # proxy and BE must agree on.
    var.self_ips_parameter_arn == "" ? {} : {
      MEANDR_SELF_IPS = var.self_ips_parameter_arn
    },
    var.redis_auth_enabled ? {
      MEANDR_REDIS_CONFIG_READER_PASSWORD = var.redis_auth_secret_arn
      MEANDR_REDIS_EVENT_WRITER_PASSWORD  = var.redis_auth_secret_arn
    } : {},
    # mTLS material for the self-hosted fleet, both planes.
    #
    # `secrets`, not `environment`: the task definition stores only the
    # Secrets Manager ARN and the agent injects the value at start, so no
    # PEM — least of all the client key — is readable via
    # describe-task-definition.
    #
    # Inline rather than a file because the runtime image is distroless.
    # Writing files would need an init container with a shell, and the Go
    # client reads either shape.
    #
    # Safe to hand a plane still on ElastiCache: the proxy ADDS this CA to
    # the system pool rather than replacing it, and ElastiCache never asks
    # for a client certificate. So the planes can cut over independently.
    var.valkey_client_secret_arn == "" ? {} : {
      MEANDR_REDIS_CONFIG_READER_CA_CERT     = "${var.valkey_client_secret_arn}:ca_crt::"
      MEANDR_REDIS_CONFIG_READER_CLIENT_CERT = "${var.valkey_client_secret_arn}:client_crt::"
      MEANDR_REDIS_CONFIG_READER_CLIENT_KEY  = "${var.valkey_client_secret_arn}:client_key::"

      MEANDR_REDIS_EVENT_WRITER_CA_CERT     = "${var.valkey_client_secret_arn}:ca_crt::"
      MEANDR_REDIS_EVENT_WRITER_CLIENT_CERT = "${var.valkey_client_secret_arn}:client_crt::"
      MEANDR_REDIS_EVENT_WRITER_CLIENT_KEY  = "${var.valkey_client_secret_arn}:client_key::"
    },
    {
      MEANDR_SESSION_SIGNING_KEY = var.session_signing_key_secret_arn
    },
  )

  # Bootstrap fallback only — Sentinel is what the client follows.
  event_writer_host = var.event_writer_endpoint

}

# The event plane — counters (rl: hash), outbound/audit streams, dedup
# locks — is a self-hosted Valkey fleet, one per region and never
# replicated across them. The proxy writes; BE consumes the streams,
# also from the master, because XREADGROUP needs a writable node.
#
# The `event_stream` ElastiCache cluster it replaced was removed
# 2026-08-25, after both sides were verified on the fleet: zero commands
# across every metric type, not merely zero connections, which never
# reaches zero while ElastiCache health-checks itself.
#
# See docs/valkey_fleets.md.

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

# Security groups are attachable ONLY AT CREATION for a network load
# balancer — there is no way to add them later, which is why this list
# forces replacement rather than an update.
#
# Required for client-IP preservation: a fronting layer will not preserve
# the caller's address through an NLB that has no security groups. Without
# preservation the proxy sees infrastructure addresses instead of clients,
# and clientguard's per-client limits collapse onto a handful of sources —
# meaningless at best, and at worst tenants throttling each other.
resource "aws_lb" "main" {
  name               = "meandr-mcp-nlb"
  internal           = var.internal_nlb
  load_balancer_type = "network"
  subnets            = var.internal_nlb ? var.private_subnet_ids : var.public_subnet_ids
  security_groups    = [aws_security_group.nlb.id]

  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = true

  tags = merge(local.base_tags, { Name = "MCP NLB" })
}

# World-open on the proxy's two ports, and correct either way: the proxy
# terminates TLS itself. Recorded in SOC-2.md §2 as expected, not a finding.
#
# Cannot be narrowed to whatever fronts it, precisely BECAUSE client IPs
# are preserved: the NLB evaluates these rules against the caller's
# address, not the intermediary's, so a narrowed range would reject every
# real request. When internal_nlb is set, reachability is bounded by the
# subnet having no route from the internet — never by these rules.
resource "aws_security_group" "nlb" {
  name        = "meandr-mcp-nlb"
  description = "MCP proxy NLB - public ingress on the proxy HTTP and TLS ports"
  vpc_id      = var.vpc_id

  tags = merge(local.base_tags, { Name = "MCP NLB" })
}

resource "aws_vpc_security_group_ingress_rule" "nlb_http" {
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Public HTTP"
}

resource "aws_vpc_security_group_ingress_rule" "nlb_tls" {
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Public TLS - proxy terminates"
}

# Health checks and forwarded traffic both leave for the task subnets.
resource "aws_vpc_security_group_egress_rule" "nlb_all" {
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = var.vpc_cidr_block
  ip_protocol       = "-1"
  description       = "To proxy tasks"
}

resource "aws_lb_target_group" "proxy" {
  name        = "meandr-mcp-proxy"
  port        = var.proxy_port
  protocol    = "TCP"
  target_type = "ip" # Fargate awsvpc mode
  vpc_id      = var.vpc_id

  # Defaults to false for ip targets, and NLB is L4 with no XFF fallback —
  # so without this the proxy sees load-balancer addresses and clientguard
  # rate-limits every tenant against the same few sources.
  preserve_client_ip = true

  health_check {
    enabled             = true
    protocol            = "TCP"
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  # Matches the proxy's MEANDR_HTTP_DRAIN_TIMEOUT default — NLB stops
  # routing new connections to this target by the time the proxy's
  # graceful-shutdown drain window closes. Bigger than the AWS default
  # of 300s isn't useful here because Fargate's hard stopTimeout cap
  # is 120s; the proxy will be SIGKILLed before a longer dereg would
  # come into play.
  deregistration_delay = 90

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

  preserve_client_ip = true

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

  # See the plain-HTTP target group above for the dereg-delay rationale.
  deregistration_delay = 90

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
  # Region-qualified because IAM is GLOBAL. Per-region is also the tighter
  # grant: the policies name this region's payload bucket, KMS replica and
  # SSM parameter, so a shared role would need the union across regions.
  name = "meandr-mcp-task-${var.env}-${local.region}"

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

# Upstream creds moved to the cred-store (DynamoDB + KMS direct) —
# see task_cred_store below + docs/credential_store.md. The proxy no
# longer reads any SM secret under meandr/tenants/* (the old
# task_tenant_secrets policy was removed). The only remaining SM grant
# on the task role is task_cert_secrets below, scoped to
# meandr/certs/* for the TLS cert pipeline (internal/cert).

# TLS cert pipeline: proxy reads its apex's wildcard cert from SM at
# meandr/certs/<env-full>/<apex> on each cold-miss handshake. Read-
# only (BE writes via the `certs:install` rake task today; ACME-
# orchestrated writes when that lands). Scoped to meandr/certs/* —
# same shape as the dev user's policy in account-development/main.tf
# but write-side dropped.
resource "aws_iam_role_policy" "task_cert_secrets" {
  name = "cert-secrets-read"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "CertSecretsRead"
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = "arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:meandr/certs/*"
    }]
  })
}

# Cred-store (proxy is read-only): DynamoDB GetItem on the cred table +
# KMS Decrypt on the CMK (NO Encrypt — only BE writes creds). The
# ciphertext stored in Dynamo is opaque KMS output; Decrypt reads the
# key ID + version from the ciphertext metadata, no key alias needed
# on the proxy side. Gated on the table ARN being set — same plan-time
# bool pattern as the other conditional policies in this module.
resource "aws_iam_role_policy" "task_cred_store" {
  count = var.cred_store_enabled ? 1 : 0

  name = "cred-store"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoCredTableRead"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:DescribeTable",
        ]
        Resource = var.creds_table_arn
      },
      {
        Sid      = "KMSDecryptCred"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = var.cred_encryption_key_arn
      },
    ]
  })
}

# Payload capture: the proxy writes request/response bodies into the
# regional payloads bucket as multipart segments, and reads one back on
# an offline approval replay (policies.md §9.2.1).
#
# AbortMultipartUpload is separate from PutObject and is NOT optional —
# the bucket's lifecycle rule cleans up what we abandon, but the proxy
# aborts deliberately on drain, and without this it cannot.
# PutObjectTagging is needed because the retention class rides as an
# object tag on the PUT itself.
#
# KMS: the bucket is SSE-KMS, so the CALLER needs GenerateDataKey to
# write and Decrypt to read. Bucket keys reduce how OFTEN S3 calls KMS,
# not whether the principal may.
resource "aws_iam_role_policy" "task_capture" {
  count = var.capture_enabled ? 1 : 0

  name = "payload-capture"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3PayloadsWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectTagging",
          "s3:GetObject",
          "s3:AbortMultipartUpload",
          "s3:ListBucketMultipartUploads",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          var.payloads_bucket_arn,
          "${var.payloads_bucket_arn}/*",
        ]
      },
      {
        Sid      = "KMSPayloadsBucket"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
        Resource = var.payload_encryption_key_arn
      },
    ]
  })
}

# The ACTION-form key, granted SEPARATELY from capture and gated on the key
# existing rather than on capture_enabled.
#
# payloadcrypt wraps upstream elicitation answers, which has nothing to do
# with payload capture — but the grant used to live in the capture policy,
# so turning capture off would have left the proxy holding the alias
# (MEANDR_PAYLOAD_KMS_KEY_ALIAS, which it refuses to boot without) and no
# permission to use it. Two features, one switch, no relationship.
resource "aws_iam_role_policy" "task_action_key" {
  count = var.action_key_enabled ? 1 : 0

  name = "action-form-key"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
      Resource = var.envelope_encryption_key_arn
    }]
  })
}

# Execution role gets SM read on the proxy-side secrets we inject as task
# def `secrets` (env-vars-from-SM). Distinct from the task role above —
# task role is the runtime identity (proxy code), execution role is what
# ECS uses to *fetch* secrets at task launch and pass them as env vars.
# Session signing key is always required; Redis AUTH is conditional.
resource "aws_iam_role_policy" "execution_secrets" {
  name = "secrets-access"
  role = module.cluster.execution_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([{
      Effect = "Allow"
      Action = "secretsmanager:GetSecretValue"
      Resource = compact([
        var.session_signing_key_secret_arn,
        var.redis_auth_enabled ? var.redis_auth_secret_arn : "",
        # The Valkey client PEMs. Missing this fails the task at LAUNCH
        # with a secret-fetch error, which reads nothing like the TLS
        # problem it would otherwise be mistaken for.
        var.valkey_client_secret_arn,
      ])
      }], var.self_ips_parameter_arn == "" ? [] : [{
      Effect   = "Allow"
      Action   = "ssm:GetParameters"
      Resource = var.self_ips_parameter_arn
    }])
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
# Accepts only what came through the load balancer. Health checks ride the
# same rules: they originate from the NLB's security group and target the
# traffic port.

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

# Source is the NLB's SECURITY GROUP, not a CIDR.
#
# The obvious rule here is 0.0.0.0/0, because client IP preservation makes
# the task see the caller's address rather than the load balancer's — so a
# CIDR narrower than the world rejects real traffic. Referencing the load
# balancer's group is the exception AWS added for exactly this: it "ensures
# that your targets accept traffic from your Network Load Balancer even if
# you enable client IP preservation… but prevents them from sending traffic
# directly to your targets."
#
# So the tasks accept only what arrived through the load balancer, and
# preservation still holds.

resource "aws_security_group_rule" "proxy_ingress_plain" {
  type              = "ingress"
  security_group_id = aws_security_group.proxy.id

  from_port                = var.proxy_port
  to_port                  = var.proxy_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nlb.id
  description              = "Plain HTTP via NLB :80 - through the load balancer only"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "proxy_ingress_tls" {
  type              = "ingress"
  security_group_id = aws_security_group.proxy.id

  from_port                = var.proxy_tls_port
  to_port                  = var.proxy_tls_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nlb.id
  description              = "TLS via NLB :443 - through the load balancer only; proxy terminates"

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

  # No init container. The proxy never opens a Postgres connection, so
  # the RDS trust store buys it nothing — and the runtime image is
  # distroless, so the container could not start anyway: no /bin/sh, and
  # the app depends on it succeeding.
  inject_rds_ca = false

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

  # Container-level health check distinct from the NLB target-group
  # health check (which gates LB routing). Without this the ECS task
  # status is "Unknown" in perpetuity.
  #
  # The runtime image is distroless — no shell, no curl, no wget — so
  # the proxy's Dockerfile copies a single static busybox binary into
  # the image just for probing. The proxy itself stays clean and only
  # serves /healthz; this CMD invokes busybox-as-wget to probe it.
  # CMD form (vs CMD-SHELL) runs the binary directly without a shell.
  #
  # `--spider` makes wget probe without writing the response body to
  # disk. Exit code 0 on HTTP 200; non-zero on connect failure or 4xx/5xx.
  #
  # startPeriod = 60s: the proxy is Go-fast on boot, but cold start
  # includes Redis connection, tenant fetcher warm-up, and TLS cert
  # load — typically 5-15s. 60s is generous headroom; the period only
  # suppresses failure counting, doesn't delay the first check.
  container_health_check = {
    command     = ["CMD", "/busybox", "wget", "-q", "--spider", "http://localhost:8080/healthz"]
    interval    = 30
    timeout     = 5
    retries     = 3
    startPeriod = 60
  }

  # Graceful-shutdown budget. The proxy's two-phase shutdown
  # (MEANDR_HTTP_DRAIN_TIMEOUT=90s + MEANDR_SHUTDOWN_TIMEOUT=25s + ~1s
  # for aggregator final-flush) tops out around 116s. 120s is the
  # Fargate hard cap on stopTimeout; we sit ~4s under it.
  #
  # NLB target-group deregistration_delay below is sized to match
  # HTTPDrainTimeout so new traffic stops arriving in lockstep with
  # the drain window — otherwise the drain runs uphill against fresh
  # connections.
  stop_timeout = 120

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
#
# SINGLE-REGION ONLY. This record names one apex, so exactly one thing in
# the environment may own it — and with two regions that would be two state
# files fighting over the same name, each convinced it was right.
#
# Multi-region hands the name to whatever fronts every region's NLB, which
# is a layer above this module and not its concern. Set false and the
# region stands up its NLB without claiming DNS — which is what lets an
# edge exist before it serves traffic.
resource "aws_route53_record" "wildcard" {
  count    = var.create_wildcard_record ? 1 : 0
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
