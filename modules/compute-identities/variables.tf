variable "env" {
  description = "Environment name; scopes the agent-token secret the task-execution role may read."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
