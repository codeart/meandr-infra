output "bucket" {
  description = "Bucket name, for the proxy's MEANDR_CAPTURE_BUCKET / BE's archive config."
  value       = aws_s3_bucket.this.id
}

output "arn" {
  description = "Bucket ARN, for IAM policies granting the writer."
  value       = aws_s3_bucket.this.arn
}
