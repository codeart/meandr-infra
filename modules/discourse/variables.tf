variable "env" {
  description = "Environment name, used in resource names and tags."
  type        = string
}

variable "region" {
  type = string
}

variable "az" {
  description = "The ONE zone everything runs in. Single-AZ by design: a forum tolerates a zone outage, and a second copy of every tier would double the bill for a site nobody is paged for."
  type        = string
}

variable "hostname" {
  description = "Public hostname the forum serves, e.g. community.meandr.com. Must resolve to the NAT's public address BEFORE first boot — Let's Encrypt validates over HTTP-01 against it."
  type        = string
}

variable "public_zone_name" {
  description = "Public Route 53 zone `hostname` lives in, looked up in the Shared account via the `aws.dns` provider. Never declared here — the zone is marketing-owned; only this record is ours."
  type        = string
}

variable "vpc_cidr" {
  description = "A /16 OUTSIDE 10/8: every 10.x is a meandr region, and this VPC is not one — it never peers with the main VPC and must not read as a region or fall inside an edge_cidrs allow-list by accident."
  type        = string
}

variable "app_instance_type" {
  description = "Graviton only — the AMI is arm64. t4g.small is 2 GiB, which with the 2 GiB swap the box adds is Discourse's documented minimum."
  type        = string
  default     = "t4g.small"
}

variable "app_root_volume_gb" {
  description = "Root volume holds the Docker image layers and Discourse's uploads/backups under /var/discourse. 30 GiB is comfortable for a small community."
  type        = number
  default     = 30
}

variable "app_capacity_slots" {
  description = <<-EOT
    Reserved slots for the app instance. ONE is right while replacement is
    destroy-then-create: the slot frees before the new instance asks for it.

    Raise to TWO before enabling the create_before_destroy cutover — the
    replacement launches while the old instance still holds its slot, and a
    full reservation refuses it. Measured 2026-09-16 on the NAT, whose own
    reservation is one slot: `ReservationCapacityExceeded`, mid-apply, with
    the EIP already detached.
  EOT
  type        = number
  default     = 1
}

variable "app_ready_timeout_seconds" {
  description = "How long to wait for a new instance to answer /srv/status before failing the apply. First boot builds the Discourse image (~7 min), so this is generous on purpose — but bounded, because the alternative to failing is moving the record to a box that never came up."
  type        = number
  default     = 900
}

variable "app_drain_duration" {
  description = "How long the old instance stays alive after the record moves: the NAT's resolver tick (≤30s) plus time for in-flight requests to finish."
  type        = string
  default     = "150s"
}

variable "nat_instance_type" {
  type    = string
  default = "t4g.nano"
}

variable "valkey_instance_type" {
  type    = string
  default = "t4g.micro"
}

variable "valkey_version" {
  description = "Must already be vendored AND uploaded to the region's artifacts bucket by the main production stack — this stack reads that object and never uploads its own."
  type        = string
}

variable "valkey_source_path" {
  description = "Local path to the vendored tarball, used only to compute the sha256 the node verifies at boot."
  type        = string
}

variable "valkey_source_bucket" {
  description = "The main stack's artifacts bucket (meandr-artifacts-<env>-<region>). Reused, not recreated."
  type        = string
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_engine_version" {
  type    = string
  default = "18.6"
}

variable "smtp_host" {
  type    = string
  default = "smtp.postmarkapp.com"
}

variable "smtp_port" {
  description = "587 with STARTTLS. EC2 blocks outbound 25 by default; do not use it."
  type        = number
  default     = 587
}

variable "notification_email" {
  description = "From address for every mail the forum sends. Must be a verified Postmark sender signature."
  type        = string
}

variable "admin_emails" {
  description = "Emails auto-granted admin on first boot (DISCOURSE_DEVELOPER_EMAILS)."
  type        = list(string)
}

variable "letsencrypt_email" {
  description = "Account email for Let's Encrypt expiry notices."
  type        = string
}

variable "alarm_topic_arns" {
  type    = list(string)
  default = []
}

variable "aws_profile" {
  description = "Operator profile for the SSM recipes runner, which executes from the operator's machine."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
