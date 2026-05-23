output "service_name" {
  description = "ECS service name. Use in `aws ecs update-service --service <name>`."
  value       = aws_ecs_service.main.name
}

output "service_arn" {
  description = "ECS service ARN."
  value       = aws_ecs_service.main.id
}

output "task_definition_arn" {
  description = "Current task definition ARN — note this is the revision Terraform created. CI/CD's `force-new-deployment` keeps the same task def but re-pulls the image."
  value       = aws_ecs_task_definition.main.arn
}

output "task_definition_family" {
  description = "Task definition family name. Same as `var.name`."
  value       = aws_ecs_task_definition.main.family
}

output "log_group_name" {
  description = "CloudWatch log group containing the service's logs."
  value       = aws_cloudwatch_log_group.main.name
}
