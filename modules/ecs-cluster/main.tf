# ECS cluster module — Fargate cluster + shared task execution role.
#
# What lives here (shared across all tasks in this cluster):
#   - The cluster itself (Fargate-only; no EC2 capacity providers)
#   - The task EXECUTION role (used by ECS to pull images + write logs + fetch
#     secrets at task-start time)
#   - CloudWatch Logs creation enabled by default on the cluster
#
# What lives in the caller (or downstream service modules):
#   - The task ROLE (runtime IAM identity for the container — varies per app)
#   - Log groups per service (created with `awslogs-create-group = true`)
#   - Security groups for the tasks themselves
#
# The execution role gets a *base* policy here (ECR pull, CloudWatch logs write).
# The caller attaches additional policies (e.g. Secrets Manager read on specific
# secrets) by creating extra `aws_iam_role_policy_attachment` resources targeting
# the role ARN exported below.

# --- Cluster ------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  configuration {
    execute_command_configuration {
      logging = "DEFAULT" # `aws ecs execute-command` logs go to CW with cluster default
    }
  }

  tags = merge(var.tags, {
    Name = var.name
  })
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# --- Task execution role ------------------------------------------------
#
# This is the role ECS itself assumes — to pull images, fetch secrets at
# task-start, write the initial log stream. NOT the role the container code
# runs as (that's the task role, defined per-service).

resource "aws_iam_role" "execution" {
  name = "${var.name}-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, {
    Name = "${var.name} execution role"
  })
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
