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

resource "aws_ecs_task_definition" "main" {
  family                   = var.name
  cpu                      = var.cpu
  memory                   = var.memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = var.container_name
    image     = var.image
    command   = var.command
    essential = true

    environment = [
      for k, v in var.environment : { name = k, value = v }
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
  }])

  tags = merge(var.tags, {
    Name = var.name
  })
}
