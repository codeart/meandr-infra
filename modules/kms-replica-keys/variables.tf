variable "keys" {
  description = "Alias name -> description, one replica each. The alias must already exist in the primary region and its key must be multi_region, which is immutable after creation."
  type        = map(string)
}

variable "deletion_window_in_days" {
  type    = number
  default = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
