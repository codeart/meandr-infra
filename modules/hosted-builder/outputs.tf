output "project_names" { value = { for arch, p in aws_codebuild_project.builder : arch => p.name } }
output "log_group_name" { value = aws_cloudwatch_log_group.builds.name }
output "registry" { value = local.registry }
