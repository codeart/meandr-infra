provider "aws" {
  region  = "us-east-1"
  profile = "meandr-production"
}

variable "github_org" {
  description = "GitHub org for trust policy scoping."
  type        = string
}

module "account_bootstrap" {
  source = "../modules/account-bootstrap"

  account_id = "393686273464" # Production
  github_org = var.github_org

  # Production only trusts:
  #   - main branch of trusted repos (the "production-track" branch), AND
  #   - GH Actions Environment "production" (with required reviewers configured in GH)
  # The combination means: a deploy needs both a green main + a human approval.
  allowed_refs = [
    "refs/heads/main",
  ]
  allowed_gh_environments = [
    "production",
  ]

  tags = {
    "meandr:env"        = "production"
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
