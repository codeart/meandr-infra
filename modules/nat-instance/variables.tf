variable "env" {
  description = "Environment name, used in resource names and tags."
  type        = string
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
