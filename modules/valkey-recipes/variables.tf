variable "instance_ids" {
  description = <<-EOT
    Every node the recipes apply to. Order does not matter; the list is
    sorted before it becomes a trigger so a caller reshuffling its module
    blocks does not look like a change.

    A node appearing here for the first time is what makes a NEW instance
    pick up the whole backlog — the same run that fans a new recipe out to
    existing nodes.
  EOT
  type        = list(string)
}

variable "recipes_dir" {
  description = <<-EOT
    Directory of numbered recipe scripts, applied in filename order.

    Defaults to the module's own `recipes/`. Override only to test a set
    without committing it — the point of keeping them in the module is
    that every environment converges on the same sequence.
  EOT
  type        = string
  default     = ""
}

variable "aws_profile" {
  description = "Profile the local SSM calls use. This runs on the operator's machine, not on a node."
  type        = string
}

variable "aws_region" {
  description = "Region the target instances live in."
  type        = string
}

variable "timeout_seconds" {
  description = "How long to wait for a node to finish its recipes before giving up on it. Generous: a recipe that installs a package pays for a dnf transaction."
  type        = number
  default     = 300
}
