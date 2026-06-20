output "policy_arn" {
  description = "Managed-policy ARN. Caller attaches via aws_iam_role_policy_attachment (for IAM roles) or aws_iam_user_policy_attachment (for IAM users)."
  value       = aws_iam_policy.deny.arn
}

output "policy_name" {
  description = "Managed-policy name. Useful for `aws iam list-policies` greps."
  value       = aws_iam_policy.deny.name
}
