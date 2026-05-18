variable "region" {
  description = "Primary region where ECR repos live and replication originates."
  type        = string
  default     = "eu-central-1"
}

variable "replication_destination_region" {
  description = "Region to replicate ECR images to. Workload accounts in this region pull from here for fast image starts."
  type        = string
  default     = "us-east-1"
}

variable "github_org" {
  description = "GitHub organization or user that owns the meandr repos (e.g. codeart). Used to scope OIDC trust policies."
  type        = string
}

variable "image_pusher_repos" {
  description = "List of GitHub repo names (within github_org) that build + push container images via CI. Trusted to assume the ECR push role."
  type        = list(string)
  default     = ["meandr-mcp", "meandr-api"]
}

variable "ecr_repos" {
  description = "ECR repo names to provision. One per service that ships a container image."
  type        = list(string)
  default     = ["meandr-mcp", "meandr-api"]
}

variable "workload_account_ids" {
  description = "Account IDs of workload accounts (Staging, Production, Dev) that need pull access to ECR. Their ECS task execution roles will get cross-account ECR permissions via the repository policy."
  type        = list(string)
  default = [
    "259534890849", # Staging
    "393686273464", # Production
    "238020582774", # Dev (may not pull container images, but harmless to include)
  ]
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default = {
    "meandr:env"        = "shared"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}
