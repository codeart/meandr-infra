output "table_name" {
  description = "Goes into MEANDR_CERT_TABLE_NAME for BE and the proxy."
  value       = aws_dynamodb_table.main.name
}

output "table_arn" {
  description = "Scopes BE's and the proxy's grants on the table."
  value       = aws_dynamodb_table.main.arn
}
