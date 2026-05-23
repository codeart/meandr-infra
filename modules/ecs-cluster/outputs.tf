output "cluster_arn" {
  description = "Cluster ARN. Pass to service modules as `cluster_arn`."
  value       = aws_ecs_cluster.main.arn
}

output "cluster_id" {
  description = "Cluster ID (same as ARN). Some AWS APIs accept ID, some ARN — both work."
  value       = aws_ecs_cluster.main.id
}

output "cluster_name" {
  description = "Cluster name. Used in `aws ecs ...` CLI commands."
  value       = aws_ecs_cluster.main.name
}

output "execution_role_arn" {
  description = "Task execution role ARN. Used in task definitions. Attach extra policies (e.g. Secrets Manager read) via the role name in the caller."
  value       = aws_iam_role.execution.arn
}

output "execution_role_name" {
  description = "Task execution role name. Use as the target for additional `aws_iam_role_policy_attachment` / `aws_iam_role_policy` resources in the caller."
  value       = aws_iam_role.execution.name
}
