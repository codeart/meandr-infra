variable "account_id" {
  description = "AWS account ID this module is applied in. Used in policy ARNs + the account-guard precondition."
  type        = string
}

variable "github_org" {
  description = "GitHub organization or user that owns the meandr repos."
  type        = string
}

variable "github_repos" {
  description = "List of GitHub repo names (within github_org) whose CI can deploy to this account."
  type        = list(string)
  default     = ["meandr-mcp", "meandr-api"]
}

variable "allowed_refs" {
  description = "List of git ref patterns (within each trusted repo) allowed to assume the deploy role. Examples: 'refs/heads/main', 'refs/heads/develop'."
  type        = list(string)
}

variable "allowed_gh_environments" {
  description = "List of GitHub Actions Environment names (within each trusted repo) allowed to assume the deploy role. Use for prod to require GH-side approval gates. Empty list = no environment-based trust."
  type        = list(string)
  default     = []
}

variable "ecs_cluster_name_prefix" {
  description = "Prefix used in the ECS cluster name. The deploy role's IAM is scoped to clusters/services matching this prefix."
  type        = string
  default     = "meandr-"
}

variable "task_role_name_prefix" {
  description = "Prefix for ECS task execution + task roles. The deploy role's iam:PassRole is scoped to roles matching this prefix."
  type        = string
  default     = "meandr-"
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default = {
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}
