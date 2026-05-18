output "github_oidc_provider_arn" {
  description = "OIDC provider ARN in this account"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "gh_actions_deploy_role_arn" {
  description = "Role ARN for CI workflows deploying ECS services in this account. Paste into GH workflow's `role-to-assume`."
  value       = aws_iam_role.gh_actions_deploy.arn
}
