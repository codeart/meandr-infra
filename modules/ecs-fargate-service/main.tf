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

locals {
  container_def = merge(
    {
      name        = var.container_name
      image       = var.image
      essential   = true
      command     = length(var.command) > 0 ? var.command : null
      stopTimeout = var.stop_timeout

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

  container_definitions = jsonencode([local.container_def])

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
