output "table_name" {
  description = "DynamoDB table name. Goes into the apps' MEANDR_CRED_TABLE_NAME env var."
  value       = aws_dynamodb_table.main.name
}

output "table_arn" {
  description = "DynamoDB table ARN. Used by app modules to build their IAM policies (DynamoDB GetItem / PutItem on this specific table only)."
  value       = aws_dynamodb_table.main.arn
}

output "table_stream_arn" {
  description = "Stream ARN. Currently unused (no DynamoDB streams enabled); reserved for the day we want change-data-capture to drive proxy invalidation directly from Dynamo instead of via cfg.server."
  value       = aws_dynamodb_table.main.stream_arn
}
