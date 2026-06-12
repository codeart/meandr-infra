variable "name" {
  description = "Service name (also used as task def family, log group suffix, autoscaling resource name). Keep short and role-specific (e.g. `meandr-api-web`, `meandr-api-gj`)."
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster ARN to deploy into. From ecs-cluster module output."
  type        = string
}

variable "execution_role_arn" {
  description = "Task execution role ARN. From ecs-cluster module output."
  type        = string
}

variable "task_role_arn" {
  description = "Task IAM role ARN — the identity the container code runs as. Defined per-app in the caller."
  type        = string
}

# --- Container ----------------------------------------------------------

variable "container_name" {
  description = "Container name (referenced by target groups and `aws ecs execute-command --container`)."
  type        = string
  default     = "app"
}

variable "image" {
  description = "Full image URI including tag. For staging use a mutable tag like `:develop`; force-new-deployment will re-pull. Production should pin `:<sha>`."
  type        = string
}

variable "command" {
  description = "Override the image's CMD. e.g. `[\"bundle\", \"exec\", \"puma\"]`."
  type        = list(string)
  default     = []
}

variable "container_port" {
  description = "Port the container listens on. Only relevant if `target_group_arn` is set (web services). Workers leave the default."
  type        = number
  default     = 3000
}

variable "cpu" {
  description = "Task-level CPU units. Fargate valid pairs: 256/512, 256/1024, 256/2048, 512/1024..4096, 1024/2048..8192, etc."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Task-level memory in MB. Must pair with `cpu` per Fargate's valid combinations."
  type        = number
  default     = 512
}

variable "environment" {
  description = "Plain environment variables (non-secret). Map of name → value."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Secrets-from-Secrets-Manager (or SSM Parameter Store). Map of env-var name → secret ARN. For JSON secrets, use `<arn>:<json-key>::` to pull a single field. Execution role must have `GetSecretValue` on these."
  type        = map(string)
  default     = {}
}

variable "container_health_check" {
  description = "Optional Docker-level health check. For web services with an ALB, leave null (target group does HTTP health checks). For workers, pass something like `{ command = [\"CMD-SHELL\", \"pgrep -f good_job\"], interval = 30, timeout = 5, retries = 3, startPeriod = 30 }`."
  type = object({
    command     = list(string)
    interval    = number
    timeout     = number
    retries     = number
    startPeriod = number
  })
  default = null
}

# --- Networking ---------------------------------------------------------

variable "subnets" {
  description = "Subnets the tasks ENI are placed in. Private subnets for everything — Fargate egresses via NAT for ECR pulls."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups attached to the task ENI. Defined by the caller because ingress rules differ by role (web allows ALB, workers allow nothing)."
  type        = list(string)
}

# --- Service ------------------------------------------------------------

variable "desired_count" {
  description = "Initial desired count. Autoscaling takes over via `min_replicas`/`max_replicas` — Terraform ignores changes to desired_count after initial create."
  type        = number
  default     = 1
}

variable "target_group_arn" {
  description = "ALB target group ARN to register tasks with. Set for web services; leave null for workers (no LB)."
  type        = string
  default     = null
}

variable "extra_load_balancers" {
  description = "Additional LB target groups + container ports to register the service with, beyond the primary `target_group_arn`/`container_port` pair. Use when a single service serves multiple listener ports (e.g. plain HTTP on one TG, TLS on another). Each entry adds a port mapping in the task def and a load_balancer block on the service."
  type = list(object({
    target_group_arn = string
    container_port   = number
  }))
  default = []
}

variable "enable_execute_command" {
  description = "Allow `aws ecs execute-command` into running tasks (Fargate SSM session). Helpful for debugging and Rails console access; should stay on for staging."
  type        = bool
  default     = true
}

variable "deployment_minimum_healthy_percent" {
  description = "During rolling deploys, the minimum percent of running tasks (vs desired) that must stay healthy. 50 = one of two replicas can be down at a time. For desired_count=1 staging, set to 0 to allow fast cycling."
  type        = number
  default     = 100
}

variable "deployment_maximum_percent" {
  description = "Maximum percent of running tasks during deploy. 200 = can run double during cutover. Default to 200 for zero-downtime rolls."
  type        = number
  default     = 200
}

# --- Autoscaling --------------------------------------------------------

variable "enable_autoscaling" {
  description = "Whether to create autoscaling policies. Disable for migrate-type one-off scenarios (use ecs-oneoff-task module for those instead)."
  type        = bool
  default     = true
}

variable "min_replicas" {
  description = "Lower bound for autoscaling. Staging default 1."
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Upper bound for autoscaling. Staging default 4 — bumps if traffic spikes but caps spend."
  type        = number
  default     = 4
}

variable "target_cpu_utilization" {
  description = "Target tracking value for ECS service CPU autoscaling. 70 means scale to keep avg CPU at ~70%."
  type        = number
  default     = 70
}

# --- Logging ------------------------------------------------------------

variable "log_group_name" {
  description = "CloudWatch log group name. Convention: `/aws/ecs/<service-name>`. Created by this module."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention. Default 30 days — per `telemetry_architecture.md`, CW is for system signals only."
  type        = number
  default     = 30
}

variable "region" {
  description = "Region for the awslogs driver config. Should match the provider region."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}
