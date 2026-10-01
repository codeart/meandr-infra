variable "env" {
  description = "Environment name, used in resource names and tags."
  type        = string
}

variable "name" {
  description = "Resource name. Empty derives `nat-<az>`. The IAM role and instance profile are ACCOUNT-global, so a second NAT in the same account and zone (an isolated VPC) must name itself."
  type        = string
  default     = ""
}

variable "forwards" {
  description = <<-EOT
    Inbound ports to DNAT from this instance's public address to a private
    host. Empty (the default) is a pure egress NAT with nothing reachable
    from the internet.

    One declaration does both halves — the SG ingress AND the nft rule — so
    an open port always leads somewhere and a forward is always reachable.
    Forwarded traffic is NOT masqueraded: the target sees the real client
    address, and return traffic comes back through this box because it is
    already the private subnet's default route.

    Each forward names its target ONE of two ways, and every forward in the
    list must use the same one:

      target_ip   = "10.60.16.10"        pinned, rendered into user-data
      target_host = "app.x.internal"     resolved on the box, re-checked

    `target_ip` is simplest, but it pins the target's address forever: the
    target cannot be replaced without reusing that IP, which forces
    destroy-before-create and a downtime window.

    `target_host` is what makes a replacement seamless. nftables resolves a
    name ONCE at load time and never again, so a resolver timer on the box
    re-checks the record every 30s and atomically swaps the rules when it
    moves. Point it at a short-TTL record the target owns, stand up the new
    target, move the record, and traffic follows within one tick — with no
    NAT replacement and no pinned address.
  EOT
  type = list(object({
    port        = number
    target_ip   = optional(string, "")
    target_host = optional(string, "")
    source_cidr = optional(string, "0.0.0.0/0")
    description = optional(string, "")
  }))
  default = []

  validation {
    condition = alltrue([
      for f in var.forwards :
      (f.target_ip != "" && f.target_host == "") || (f.target_ip == "" && f.target_host != "")
    ])
    error_message = "each forward needs exactly one of target_ip or target_host."
  }

  validation {
    # The resolver owns the whole prerouting chain when it runs, so a static
    # rule mixed in would be flushed away on the first re-resolve.
    condition     = length(distinct([for f in var.forwards : f.target_host == ""])) <= 1
    error_message = "forwards must not mix target_ip and target_host — pick one for the whole list."
  }
}

variable "az" {
  description = "AZ this instance lives in. Its ENI, EIP and subnet are all fixed to this zone, so changing it replaces the address."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "PUBLIC subnet in `az`. A NAT instance reaches the internet through the IGW like any other public host; putting it in a private subnet creates a routing loop through itself."
  type        = string
}

variable "vpc_cidr" {
  description = <<-EOT
    The VPC's CIDR, and the ONLY source allowed to send traffic through
    this instance.

    An open NAT is an open proxy: anything that can reach it egresses with
    our address and our reputation. The instance holds a public IP, so this
    is the boundary — not a private subnet it happens to sit behind.
  EOT
  type        = string
}

variable "instance_type" {
  description = "Graviton only — the AMI is arm64. Sized by packets, not bandwidth: t4g.nano handles thousands of connections, far past what a proxy tier's upstream calls generate."
  type        = string
  default     = "t4g.nano"
}

variable "root_volume_gb" {
  description = "Root volume. Nothing is stored here; 8 GiB is the AL2023 image plus room for logs."
  type        = number
  default     = 8
}

variable "ami_id" {
  description = "Pin an AMI. Empty tracks the latest AL2023 arm64, which only moves on deliberate replacement (see the lifecycle block)."
  type        = string
  default     = ""
}

variable "alarm_topic_arns" {
  description = "Where the conntrack alarm goes. Empty leaves the alarm visible in the console but silent — fine for staging, wrong for production."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
