output "topic_arn" {
  description = "The region's security alert topic."
  value       = aws_sns_topic.security.arn
}
