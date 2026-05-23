provider "aws" {
  region  = "eu-central-1"
  profile = "meandr-staging"
}

variable "github_org" {
  description = "GitHub org for trust policy scoping."
  type        = string
}

module "account_bootstrap" {
  source = "../modules/account-bootstrap"

  account_id = "259534890849" # Staging
  github_org = var.github_org

  # Staging trusts develop + main from image-pushing repos.
  # `staging` GH Environment is also trusted — workflow jobs use it to scope
  # secrets/vars and (optionally) add reviewer gates. When a job sets
  # `environment: staging`, GitHub OIDC sends an environment-based subject
  # claim instead of a ref-based one; both forms must be in the allow list.
  allowed_refs = [
    "refs/heads/main",
    "refs/heads/develop",
  ]
  allowed_gh_environments = [
    "staging",
  ]

  tags = {
    "meandr:env"        = "staging"
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }
}

output "github_oidc_provider_arn" {
  value = module.account_bootstrap.github_oidc_provider_arn
}

output "gh_actions_deploy_role_arn" {
  value = module.account_bootstrap.gh_actions_deploy_role_arn
}
