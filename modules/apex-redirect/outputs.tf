output "distribution_id" {
  description = "The CloudFront distribution answering the apex."
  value       = aws_cloudfront_distribution.redirect.id
}
