output "name" {
  description = "Database name, for the app's Athena config and for IAM policies scoping catalog access."
  value       = aws_glue_catalog_database.this.name
}

output "arn" {
  description = "Database ARN, for IAM policies. Table grants extend this with `/*` under the table resource form."
  value       = aws_glue_catalog_database.this.arn
}
