output "policy_id" {
  description = "Organizations policy ID. Useful for `aws organizations describe-policy` greps and for manual attach/detach via CLI."
  value       = aws_organizations_policy.deny.id
}

output "policy_arn" {
  description = "Organizations policy ARN."
  value       = aws_organizations_policy.deny.arn
}
