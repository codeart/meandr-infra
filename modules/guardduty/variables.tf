variable "env" {
  type = string
}

variable "alert_emails" {
  description = "Who receives findings. Each address confirms its subscription once per region."
  type        = list(string)
}

variable "min_severity" {
  description = "Lowest severity mailed: 4 is medium, 7 high."
  type        = number
  default     = 4
}

variable "tags" {
  type    = map(string)
  default = {}
}
