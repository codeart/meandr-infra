# One-off ECS task module — task definition without a service.
#
# For migrations, seed scripts, debug shells — anything where you want
#   `aws ecs run-task --task-definition <name>` to launch a Fargate task,
#   run to completion, log to CW, then exit.
#
# Same shape as ecs-fargate-service but: no service, no autoscaling, no LB,
# no port mappings. The caller invokes via run-task on demand (or CI does it
# on push as part of the deploy pipeline).

resource "aws_cloudwatch_log_group" "main" {
  name              = var.log_group_name
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = var.log_group_name
  })
}

# RDS trust store, same injection as ecs-fargate-service and for the same
# reason — see that module for why the bundle cannot come from the OS.
#
# It matters MORE here: a migration is the first thing a deploy runs and
# the only one that writes schema. A migrate task that cannot verify the
# certificate fails the deploy, which is the correct outcome but an
# expensive way to discover a missing file.
module "rds_ca" {
  source = "../rds-ca"
  region = var.region
}

locals {
  rds_cert_dir  = module.rds_ca.dir
  rds_cert_file = module.rds_ca.filename

  cert_init_def = {
    name      = "rds-ca"
    image     = var.image
    essential = false

    # Root: the volume mount point is root-owned, so the image's non-root
    # user cannot create a file in it. See ecs-fargate-service.
    user = "0"

    entryPoint = ["/bin/sh", "-c"]
    command    = ["printf '%s' \"$RDS_CA_BUNDLE\" > ${local.rds_cert_file} && chmod 0444 ${local.rds_cert_file}"]

    environment = [
      { name = "RDS_CA_BUNDLE", value = module.rds_ca.pem }
    ]

    mountPoints = [
      { sourceVolume = "rds-ca", containerPath = local.rds_cert_dir, readOnly = false }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.main.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
  }
}

resource "aws_ecs_task_definition" "main" {
  family                   = var.name
  cpu                      = var.cpu
  memory                   = var.memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  # Must match ecs-fargate-service: these run the same image as the
  # services, and both apps build linux/arm64 only. Left at Fargate's
  # X86_64 default this would place nowhere, and the failure surfaces
  # as a stuck deploy rather than a bad task definition.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  volume {
    name = "rds-ca"
  }

  container_definitions = jsonencode([
    {
      name      = var.container_name
      image     = var.image
      command   = var.command
      essential = true

      mountPoints = [
        { sourceVolume = "rds-ca", containerPath = local.rds_cert_dir, readOnly = true }
      ]

      dependsOn = [
        { containerName = "rds-ca", condition = "SUCCESS" }
      ]

      environment = [
        for k, v in merge({ PGSSLROOTCERT = local.rds_cert_file }, var.environment) :
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
    local.cert_init_def,
  ])

  tags = merge(var.tags, {
    Name = var.name
  })
}
