variable "name" {
  description = "Prefix for the CloudFront function's name, e.g. `meandr-production`."
  type        = string
}

variable "apex" {
  description = "Bare zone apex to answer, e.g. `meandr.io`. The zone must be public and reachable through the `aws.dns` provider."
  type        = string
}

variable "target" {
  description = "Absolute URL every request is redirected to, e.g. `https://meandr.com/`."
  type        = string
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
