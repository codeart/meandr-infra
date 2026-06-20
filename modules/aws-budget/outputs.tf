output "budget_id" {
  description = "Budget identifier (account-scoped name). For aws-cli look-ups + console links."
  value       = aws_budgets_budget.main.id
}

output "sns_topic_arn" {
  description = "SNS topic ARN. Add more subscribers (Slack via Lambda, PagerDuty, etc.) by attaching aws_sns_topic_subscription outside this module."
  value       = aws_sns_topic.budget_alerts.arn
}
