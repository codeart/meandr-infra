variable "name" {
  description = "Table name, `meandr-certs-<env>`: one per env, replicated to every region."
  type        = string

  validation {
    condition     = length(var.name) <= 255 && can(regex("^[a-zA-Z0-9_.-]+$", var.name))
    error_message = "DynamoDB table name must be ≤255 chars and match [a-zA-Z0-9_.-]+."
  }
}

variable "pitr_enabled" {
  description = "Point-in-time recovery, 35 days."
  type        = bool
  default     = false
}

variable "deletion_protection_enabled" {
  description = "Block a destroy of the table, and of a protected replica."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags applied to the table."
  type        = map(string)
  default     = {}
}
