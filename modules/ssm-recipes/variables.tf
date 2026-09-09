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

    REQUIRED, and it should come from the fleet module that owns the
    recipes — `module.valkey.recipes_dir`, not a path typed here. The set
    and the nodes it targets are then chosen together, in one place, and
    every environment converges on the same sequence.

    There is no default. A runner that guesses which recipes to send is a
    runner that can send Valkey's to a NAT box.
  EOT
  type        = string
}

variable "label" {
  description = "Fleet name, used as the SSM command comment. It is how someone reading a node's command history tells which set ran — a NAT box labelled `valkey` is worse than no label."
  type        = string
}

variable "aws_profile" {
  description = "Profile the local SSM calls use. This runs on the operator's machine, not on a node."
  type        = string
}

variable "aws_region" {
  description = "Region the target instances live in."
  type        = string
}

variable "register_timeout_seconds" {
  description = <<-EOT
    How long to wait for every target to appear Online in SSM before
    giving up.

    Terraform calls an instance created when EC2 returns, but the agent
    registers a minute or two later — and a NEW node is precisely what
    re-triggers this resource, so without the wait the first run always
    races. Generous: a node that is also compiling Valkey has other
    things competing for a small CPU.
  EOT
  type        = number
  default     = 600
}

variable "timeout_seconds" {
  description = "How long to wait for a node to finish its recipes before giving up on it. Generous: a recipe that installs a package pays for a dnf transaction."
  type        = number
  default     = 300
}
