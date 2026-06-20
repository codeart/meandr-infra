variable "name" {
  description = "Logical name. Used for the AWS Anomaly Monitor + Subscription resources. Visible in the Cost Explorer console."
  type        = string
}

variable "threshold_usd" {
  description = "Absolute dollar deviation from the ML-predicted normal that triggers an alert. AWS computes a daily expected-spend baseline per service; an actual that exceeds the baseline by this many USD is flagged. Smaller value = noisier (catches subtle spikes), larger = quieter. Suggested: $5 dev, $10 staging, $20 production. The unit is dollars-over-expected, not absolute spend."
  type        = number

  validation {
    condition     = var.threshold_usd > 0
    error_message = "threshold_usd must be > 0."
  }
}

variable "sns_topic_arn" {
  description = "SNS topic to publish anomaly alerts to. Reuse the budget topic from modules/aws-budget so all cost-control notifications land in the same place. The SNS topic policy must allow `costalerts.amazonaws.com` to Publish — see the module main.tf for the data-source dance that figures out whether to update the policy or trust the caller."
  type        = string
}

variable "tags" {
  description = "Tags applied to the anomaly monitor + subscription."
  type        = map(string)
  default     = {}
}
