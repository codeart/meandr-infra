variable "name" {
  description = "Task definition family name. e.g. `meandr-api-migrate`. Invoked via `aws ecs run-task --task-definition <name>`."
  type        = string
}

variable "execution_role_arn" {
  description = "Task execution role ARN. From ecs-cluster module output."
  type        = string
}

variable "valkey_client_secret_arn" {
  description = <<-EOT
    Secrets Manager ARN holding `{ca_crt, client_crt, client_key}`,
    written into the task as files alongside the RDS bundle.

    A one-off task needs these whenever the app builds Redis clients at
    BOOT — Rails eager-loads, so a migration fails before it reaches a
    migration if the fleet demands a certificate it does not have.

    Via ECS `secrets`, never `environment`: the task definition holds
    only the ARN.
  EOT
  type        = string
  default     = ""
}

variable "task_role_arn" {
  description = "Task IAM role ARN. The role the migration / seed code runs as."
  type        = string
}

variable "container_name" {
  description = "Container name. Convention `app` to match service modules."
  type        = string
  default     = "app"
}

variable "image" {
  description = "Full image URI including tag. Should be the SAME image as the long-running services — only the command differs."
  type        = string
}

variable "command" {
  description = "Container CMD. e.g. `[\"bundle\", \"exec\", \"rails\", \"db:migrate\"]`."
  type        = list(string)
}

variable "cpu" {
  description = "CPU units. Default 512 (0.5 vCPU) — bigger than runtime services since schema loads can be CPU-heavy."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Memory in MB. Default 1024 — same reason as CPU."
  type        = number
  default     = 1024
}

variable "environment" {
  description = "Plain environment variables. Map of name → value."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Secrets from Secrets Manager. Map of env-var name → secret ARN (or `<arn>:<json-key>::`)."
  type        = map(string)
  default     = {}
}

variable "log_group_name" {
  description = "CloudWatch log group name. Created by this module."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 30
}

variable "region" {
  description = "Region for awslogs driver config."
  type        = string
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
