variable "env" {
  description = "Environment name; scopes the agent-token secret the task-execution role may read."
  type        = string
}

variable "image_account_id" {
  description = "Account holding the ECR repositories the fleet pulls (the shared account)."
  type        = string
  default     = "303529433558"
}

variable "tags" {
  type    = map(string)
  default = {}
}
