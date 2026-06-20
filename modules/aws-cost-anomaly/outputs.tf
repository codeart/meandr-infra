output "monitor_arn" {
  description = "Anomaly monitor ARN. For diagnostic CLI calls (`aws ce get-anomalies --monitor-arn …`)."
  value       = aws_ce_anomaly_monitor.main.arn
}

output "subscription_arn" {
  description = "Anomaly subscription ARN."
  value       = aws_ce_anomaly_subscription.main.arn
}
