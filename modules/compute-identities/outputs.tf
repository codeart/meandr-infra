output "node_role_arn" { value = aws_iam_role.node.arn }
output "instance_profile_arn" { value = aws_iam_instance_profile.node.arn }
output "task_execution_role_arn" { value = aws_iam_role.task_execution.arn }
output "events_invoke_role_arn" { value = aws_iam_role.events_invoke.arn }
