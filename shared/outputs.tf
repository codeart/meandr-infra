output "github_oidc_provider_arn" {
  description = "OIDC provider ARN for GitHub Actions in Shared account. Workload accounts get their own OIDC providers."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "gh_actions_ecr_push_role_arn" {
  description = "Role ARN for CI workflows in image-pushing repos (meandr-mcp, meandr-api). Paste into GH workflow's `role-to-assume`."
  value       = aws_iam_role.gh_actions_ecr_push.arn
}

output "ecr_repos" {
  description = "Map of service name to ECR repo URLs (eu-central-1 primary)."
  value       = { for r in aws_ecr_repository.service : r.name => r.repository_url }
}

output "ecr_repo_us_east_1_urls" {
  description = "Replicated ECR repo URLs in us-east-1. Workload tasks in us-east-1 pull from here once replication has populated."
  value = {
    for name in var.ecr_repos :
    name => "${local.shared_account_id}.dkr.ecr.${var.replication_destination_region}.amazonaws.com/${name}"
  }
}
