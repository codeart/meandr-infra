variable "name" {
  description = "Logical name for the budget. Shown in the AWS console; also used to derive the SNS topic name."
  type        = string
}

variable "amount_usd" {
  description = "Budget limit in USD for one period (see time_unit). The notification thresholds are percentages of this number."
  type        = number
}

variable "time_unit" {
  description = "Budget reset cadence. Daily is the right call for catching runaway costs early; monthly is the standard accounting unit. AWS valid: DAILY / MONTHLY / QUARTERLY / ANNUALLY."
  type        = string
  default     = "DAILY"

  validation {
    condition     = contains(["DAILY", "MONTHLY", "QUARTERLY", "ANNUALLY"], var.time_unit)
    error_message = "time_unit must be DAILY, MONTHLY, QUARTERLY, or ANNUALLY."
  }
}

variable "threshold_percents" {
  description = "Notification thresholds as percentages of amount_usd. Each entry generates an ACTUAL notification (fires when spend literally crosses the line, 8-24h lag in Cost Explorer data). For MONTHLY+ budgets ONLY, each entry ALSO generates a FORECASTED notification (fires same-day on AWS's projection that you'll cross by period end) — DAILY budgets don't support FORECASTED because there isn't enough intra-day signal to project credibly. Example: [50, 75, 95, 100] for production monthly tiers; [95] for dev/staging daily alert-only."
  type        = list(number)

  validation {
    condition     = length(var.threshold_percents) > 0 && length(var.threshold_percents) <= 5
    error_message = "Provide 1-5 threshold percentages (AWS caps at 5 notifications per budget; we double-count FORECASTED+ACTUAL but they're treated as separate notifications)."
  }
}

variable "notification_emails" {
  description = "Email addresses to subscribe to the budget's SNS topic. Up to 10 per AWS limit. Topic + subscriptions are scoped to this budget."
  type        = list(string)
}

variable "tags" {
  description = "Tags applied to the SNS topic + budget."
  type        = map(string)
  default     = {}
}
