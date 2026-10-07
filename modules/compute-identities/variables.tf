variable "image_account_id" {
  description = "Account holding the ECR repositories the fleet pulls (the shared account)."
  type        = string
  default     = "303529433558"
}

variable "tags" {
  type    = map(string)
  default = {}
}
