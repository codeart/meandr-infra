output "key_arns" {
  description = "Alias name -> replica key ARN, for IAM scoping."
  value       = { for k, v in aws_kms_replica_key.this : k => v.arn }
}

output "alias_names" {
  description = "Alias name -> `alias/<name>`, for callers that wrap with an alias rather than an ARN."
  value       = { for k, v in aws_kms_alias.this : k => v.name }
}
