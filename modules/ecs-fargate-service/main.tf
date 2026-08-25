# ECS Fargate service module — single-container task definition + service.
#
# Handles both web-facing services (with ALB target group) and workers (no ALB)
# via the optional `target_group_arn` variable. Worker services additionally
# typically set a `container_health_check` because there's no ALB to do it.
#
# Task definitions are owned by Terraform end-to-end. CI/CD does NOT register
# new task def revisions — it just builds an image, pushes to the same mutable
# tag (`:develop`/`:main`), and calls `aws ecs update-service --force-new-deployment`.
# ECS re-pulls the tag and rolls tasks. See `docs/meandr_api_first_deploy.md`
# for the design rationale.

# --- Log group ----------------------------------------------------------

resource "aws_cloudwatch_log_group" "main" {
  name              = var.log_group_name
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = var.log_group_name
  })
}

# --- Task definition ----------------------------------------------------

module "rds_ca" {
  source = "../rds-ca"
  region = var.region
}

locals {
  # RDS trust store, injected rather than baked into an image.
  #
  # `sslmode=verify-full` needs a root the OS does not carry: the RDS
  # roots are a PRIVATE Amazon PKI, self-signed and absent from every
  # public trust store. Putting the bundle here means the app images stay
  # unaware of it and any future task gets it for free.
  #
  # Not a secret — it is a public certificate — so it rides the task
  # definition directly. That also sidesteps Secrets Manager's 64 KB cap,
  # which the 165 KB global bundle would exceed. The REGIONAL bundle is
  # the right scope anyway: a task only reaches RDS in its own region.
  #
  # Vendored per region by modules/rds-ca; a region with no bundle fails
  # at plan.
  rds_cert_dir  = module.rds_ca.dir
  rds_cert_file = module.rds_ca.filename

  # The self-hosted Valkey PKI, injected the same way but sourced
  # differently: these are PRIVATE, so they arrive through ECS `secrets`
  # rather than `environment`. A client key in `environment` sits in
  # plaintext in every describe-task-definition, forever.
  #
  # Empty ARN skips the whole thing — a task whose planes are still on
  # ElastiCache needs no client half.
  #
  # The init container exists to write files. A task that needs no files
  # should not have one — and CANNOT, if its image is distroless: there
  # is no /bin/sh to run, the container fails to start, and because the
  # app depends on it the whole task never starts.
  init_enabled = var.inject_rds_ca

  valkey_certs   = var.inject_rds_ca && var.valkey_client_secret_arn != ""
  valkey_dir     = "/var/run/valkey"
  valkey_ca_file = "${local.valkey_dir}/ca.pem"
  valkey_crt     = "${local.valkey_dir}/client.crt"
  valkey_key     = "${local.valkey_dir}/client.key"

  # 0444 including the key. The volume is task-scoped and both containers
  # are ours, so "world" is this task; the alternative is guessing each
  # image's uid to chown to, which breaks the moment an image changes.
  cert_init_cmds = concat(
    [
      "printf '%s' \"$RDS_CA_BUNDLE\" > ${local.rds_cert_file}",
      "chmod 0444 ${local.rds_cert_file}",
    ],
    local.valkey_certs ? [
      "printf '%s' \"$VALKEY_CA_CRT\" > ${local.valkey_ca_file}",
      "printf '%s' \"$VALKEY_CLIENT_CRT\" > ${local.valkey_crt}",
      "printf '%s' \"$VALKEY_CLIENT_KEY\" > ${local.valkey_key}",
      "chmod 0444 ${local.valkey_ca_file} ${local.valkey_crt} ${local.valkey_key}",
    ] : [],
  )

  # Writes the material, then exits. Reuses the app image so the task
  # pulls nothing extra, and Fargate bills the task rather than the
  # container, so this costs neither a pull nor a cent.
  cert_init_def = {
    name      = "rds-ca"
    image     = var.init_image != "" ? var.init_image : var.image
    essential = false

    # Root, overriding the image's USER. The volume's mount point is
    # created root-owned 0755, so the app image's non-root user cannot
    # create a file in it — the write fails with EACCES and the task
    # never starts. Only this container is root; the app keeps its own
    # user and mounts the result read-only.
    user = "0"

    entryPoint = ["/bin/sh", "-c"]
    command    = [join(" && ", local.cert_init_cmds)]

    environment = [
      { name = "RDS_CA_BUNDLE", value = module.rds_ca.pem }
    ]

    secrets = local.valkey_certs ? [
      { name = "VALKEY_CA_CRT", valueFrom = "${var.valkey_client_secret_arn}:ca_crt::" },
      { name = "VALKEY_CLIENT_CRT", valueFrom = "${var.valkey_client_secret_arn}:client_crt::" },
      { name = "VALKEY_CLIENT_KEY", valueFrom = "${var.valkey_client_secret_arn}:client_key::" },
    ] : []

    mountPoints = concat(
      [{ sourceVolume = "rds-ca", containerPath = local.rds_cert_dir, readOnly = false }],
      local.valkey_certs ? [{ sourceVolume = "valkey-ca", containerPath = local.valkey_dir, readOnly = false }] : [],
    )

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.main.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
  }

  container_def = merge(
    {
      name        = var.container_name
      image       = var.image
      essential   = true
      command     = length(var.command) > 0 ? var.command : null
      stopTimeout = var.stop_timeout

      # Read-only: the app consumes the trust store, it does not curate it.
      mountPoints = local.init_enabled ? concat(
        [{ sourceVolume = "rds-ca", containerPath = local.rds_cert_dir, readOnly = true }],
        local.valkey_certs ? [{ sourceVolume = "valkey-ca", containerPath = local.valkey_dir, readOnly = true }] : [],
      ) : []

      # SUCCESS, not COMPLETE — COMPLETE only means the init container
      # exited, whatever its status, so a failed write would still start
      # the app and surface later as a certificate error that reads like a
      # database outage. Fail the task where the cause is visible.
      dependsOn = local.init_enabled ? [
        { containerName = "rds-ca", condition = "SUCCESS" }
      ] : null

      portMappings = concat(
        var.target_group_arn != null ? [
          {
            containerPort = var.container_port
            protocol      = "tcp"
          }
        ] : [],
        [
          for lb in var.extra_load_balancers : {
            containerPort = lb.container_port
            protocol      = "tcp"
          }
        ],
      )

      # PGSSLROOTCERT is added for every task that HAS the bundle, not
      # opted into. libpq reads it with no application wiring, so a
      # service that connects to Postgres verifies the certificate by
      # default rather than because someone remembered to. A caller may
      # still override it.
      environment = [
        for k, v in merge(local.init_enabled ? { PGSSLROOTCERT = local.rds_cert_file } : {}, var.environment) :
        { name = k, value = v }
      ]

      secrets = [
        for k, v in var.secrets : { name = k, valueFrom = v }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.main.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs"
        }
      }
    },
    var.container_health_check != null ? { healthCheck = var.container_health_check } : {}
  )
}

resource "aws_ecs_task_definition" "main" {
  family                   = var.name
  cpu                      = var.cpu
  memory                   = var.memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  # Graviton — ~20% cheaper per vCPU-hour for identical work, and ECS
  # compute is the line that grows fastest as traffic does.
  #
  # PINNED, not left to Fargate's X86_64 default: an unset runtime_platform
  # silently keeps every task on amd64 no matter what the image contains,
  # so the saving would depend on a default rather than a decision.
  #
  # Both apps now build linux/arm64 only — an image that predates this
  # will not run here.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  # Task-scoped scratch volume, shared between the init container that
  # writes the trust store and the app that reads it. Ephemeral by
  # design: it is rebuilt from the task definition on every start, so
  # there is no state to drift and nothing to rotate.
  dynamic "volume" {
    for_each = local.init_enabled ? [1] : []
    content {
      name = "rds-ca"
    }
  }

  dynamic "volume" {
    for_each = local.valkey_certs ? [1] : []
    content {
      name = "valkey-ca"
    }
  }

  # concat, not a conditional: Terraform requires both branches of a
  # ternary to share a type, and a 2-tuple never matches a 1-tuple.
  container_definitions = jsonencode(concat(
    [local.container_def],
    local.init_enabled ? [local.cert_init_def] : [],
  ))

  tags = merge(var.tags, {
    Name = var.name
  })
}

# --- Service ------------------------------------------------------------

resource "aws_ecs_service" "main" {
  name                               = var.name
  cluster                            = var.cluster_arn
  task_definition                    = aws_ecs_task_definition.main.arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  enable_execute_command             = var.enable_execute_command
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent

  # Abort + roll back on deploys where new tasks fail to stabilize
  # (bad image, missing env / secret, health-check failing). Catches
  # the common "broken revision stuck rolling forever" mode.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnets
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn != null ? [1] : []
    content {
      target_group_arn = var.target_group_arn
      container_name   = var.container_name
      container_port   = var.container_port
    }
  }

  dynamic "load_balancer" {
    for_each = var.extra_load_balancers
    content {
      target_group_arn = load_balancer.value.target_group_arn
      container_name   = var.container_name
      container_port   = load_balancer.value.container_port
    }
  }

  # When autoscaling is on, the desired_count gets managed externally — don't
  # fight it on every plan. Same for force-new-deployment behaviour where the
  # task_definition ARN doesn't change but the underlying image does.
  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = merge(var.tags, {
    Name = var.name
  })
}

# --- Autoscaling --------------------------------------------------------

resource "aws_appautoscaling_target" "main" {
  count = var.enable_autoscaling ? 1 : 0

  service_namespace  = "ecs"
  resource_id        = "service/${split("/", var.cluster_arn)[1]}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_replicas
  max_capacity       = var.max_replicas
}

resource "aws_appautoscaling_policy" "cpu" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.main[0].service_namespace
  resource_id        = aws_appautoscaling_target.main[0].resource_id
  scalable_dimension = aws_appautoscaling_target.main[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.target_cpu_utilization
    scale_in_cooldown  = 300 # 5 min — give traffic time to settle before scaling down
    scale_out_cooldown = 60  # 1 min — scale out fast when CPU spikes
  }
}
