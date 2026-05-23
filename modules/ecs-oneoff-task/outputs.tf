output "task_definition_arn" {
  description = "Task definition ARN. Pass to `aws ecs run-task --task-definition <family>:<rev>` or just `<family>` for latest."
  value       = aws_ecs_task_definition.main.arn
}

output "task_definition_family" {
  description = "Task definition family. CI uses this as the `--task-definition` argument so it always picks the latest revision."
  value       = aws_ecs_task_definition.main.family
}

output "log_group_name" {
  description = "CloudWatch log group containing task output."
  value       = aws_cloudwatch_log_group.main.name
}
