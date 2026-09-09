variable "linux_shell" {
  description = "What a Linux session starts. `bash -l` is a login shell, so /etc/profile runs and the prompt carries the hostname; the AWS default is a bare `sh` that reads no profile."
  type        = string
  default     = "bash -l"
}

variable "tags" {
  type    = map(string)
  default = {}
}
