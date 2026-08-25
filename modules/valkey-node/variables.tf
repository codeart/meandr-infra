variable "fleet" {
  description = <<-EOT
    Which Valkey fleet this node belongs to — `config`, `events`, and
    whatever comes after.

    Every name the module derives hangs off this: the hostname, the master
    record, the security group, the IAM role, the Sentinel master name.
    That is the point. A second fleet in the same VPC collides on all five
    unless the fleet is part of them, and discovering that after an apply
    means moving state rather than editing a string.
  EOT
  type        = string

  validation {
    # Lowercase and dash-free because it lands in DNS labels next to the
    # node id; a dot or an underscore here produces a name that resolves
    # to nothing and a cert that matches nothing.
    condition     = can(regex("^[a-z0-9]+$", var.fleet))
    error_message = "fleet must be lowercase alphanumeric (e.g. config, events)."
  }
}

variable "node" {
  description = <<-EOT
    This node's id WITHIN its fleet — `a`, `b`, `euw1`. Not the full name:
    the module builds `valkey-<fleet>-<node>` so the convention cannot be
    broken from a caller.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.node))
    error_message = "node must be lowercase alphanumeric (e.g. a, b, euw1)."
  }
}

variable "role" {
  description = <<-EOT
    BOOTSTRAP TIE-BREAK ONLY — not the node's role.

    The actual role is derived at boot by resolving the master record: a
    node that finds a master other than itself becomes its replica, whoever
    that master is and whichever node is being replaced. That is what makes
    replacement safe after a failover, when a declared role would relaunch
    yesterday's master as a second, empty one.

    This variable matters exactly once, before the record exists and
    something has to decide:
      `master`  — may become master if no record resolves.
      `replica` — waits for the record instead. Never self-promotes.

    Give it to whichever node the caller bootstraps the record from. After
    that it has no effect, and Sentinel owns the role.
  EOT
  type        = string

  validation {
    condition     = contains(["master", "replica"], var.role)
    error_message = "role must be master or replica."
  }
}

variable "promotable" {
  description = <<-EOT
    Whether Sentinel may ever promote this node to master.

    FALSE for every out-of-region replica, and that is the whole safety
    property: it sets `replica-priority 0`, which makes the node
    structurally ineligible rather than merely unlikely. Only the API
    region can hold the master (see events/flows — the write path assumes
    it), so a regional failover must be impossible, not just improbable.
  EOT
  type        = bool
  default     = true
}

variable "run_sentinel" {
  description = <<-EOT
    Run Sentinel on this node.

    ONLY in the region that may hold the master. Any Sentinel anywhere
    participates in quorum, so one across a WAN turns a transatlantic blip
    into a false promotion — the failure this topology exists to avoid.
  EOT
  type        = bool
  default     = false
}

variable "sentinel_quorum" {
  description = <<-EOT
    How many Sentinels must agree the master is down before an automatic
    failover starts. A majority of the TOTAL Sentinel count across every
    region — 2 of 3, 3 of 5.

    Fleet-wide constant: every node must be given the same number, or the
    Sentinels disagree about what agreement means. Ignored unless
    run_sentinel.
  EOT
  type        = number
  default     = 2
}

variable "valkey_version" {
  description = <<-EOT
    Valkey version to compile, e.g. `9.1.1`. Must match a vendored tarball
    at `modules/valkey-node/vendor/valkey-<version>.tar.gz` — a version
    with no vendored source fails at plan, not at boot.

    Source-built rather than packaged, because nothing packages 9.x for
    aarch64: AL2023 stops at 8.0.3, EPEL has no valkey, redis.io publishes
    x86_64 only, and valkey.io's binaries are Ubuntu-linked against a
    newer glibc than ours. Hash-field TTLs (HEXPIRE) are 9.x-only and the
    event tier needs them.

    PINNED deliberately. A node replaced 18 months from now must run the
    version you chose, not whatever is current — and the direction matters:
    a replica newer than its master is safe, a master newer than its
    replicas is not. Upgrade replicas first, master last.
  EOT
  type        = string
}

variable "valkey_source_bucket" {
  description = <<-EOT
    Bucket holding the vendored Valkey source, uploaded by the same apply
    that creates this node.

    Must be in the node's own region and account. The VPC's S3 gateway
    endpoint only routes to the regional S3 service, so a bucket anywhere
    else turns the boot fetch into NAT egress — which would put the one
    dependency we vendored the source to avoid straight back on the boot
    path, just wearing a different hat.
  EOT
  type        = string
}

variable "valkey_source_sha256" {
  description = <<-EOT
    sha256 of the vendored source tarball. Verified on the node before
    anything is unpacked or compiled.

    Callers pass `filesha256()` of the vendored file, so this is derived
    rather than typed — it cannot drift from what is actually in the repo,
    and there is no digest to remember to update on a version bump.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.valkey_source_sha256))
    error_message = "valkey_source_sha256 must be 64 lowercase hex characters — pass filesha256() of the vendored tarball."
  }
}

variable "auth_secret_arn" {
  description = "Secrets Manager ARN holding the AUTH token. Fetched at boot by the instance role rather than passed in user-data, which is readable from instance metadata by anything on the box."
  type        = string
}

variable "tls_secret_arn" {
  description = <<-EOT
    Secrets Manager ARN holding `{ca_crt, node_crt, node_key}` as JSON —
    the TLS material for every Valkey node in this environment.

    Plaintext is disabled entirely (`port 0`), so clients connect with
    rediss:// and there is no listener to fall back to. One keypair shared
    across the fleet rather than one per node: every node holds the same
    AUTH and the same data, so per-node keys would add rotation work
    without narrowing any blast radius.
  EOT
  type        = string
}

variable "instance_type" {
  description = "ARM64 instance type. Graviton — these run for years, so the per-hour saving compounds and nothing here needs x86."
  type        = string
  default     = "t4g.micro"
}

variable "sentinel_only" {
  description = <<-EOT
    Run Sentinel and no Valkey — an arbiter.

    Its whole job is to be the third vote. Two Sentinels can never agree
    when one is gone, so a two-node fleet has no automatic failover at all;
    a third makes quorum reachable. Put it in a THIRD zone, or losing one
    zone still costs two of three votes.

    Cheap because it holds no data: a nano arbiter serves a fleet of any
    size. It still compiles Valkey — valkey-sentinel comes from the same
    build — and still needs the CA, AUTH and the master record.
  EOT
  type        = bool
  default     = false
}

variable "backup_bucket" {
  description = <<-EOT
    Bucket for RDB backups. Empty disables them entirely — no script, no
    timer, no IAM.

    Leave empty for edge regions: their nodes are read-only copies of a
    fleet the API region already backs up, so a second copy buys nothing
    and ships the dataset across a WAN to do it.
  EOT
  type        = string
  default     = ""
}

variable "backup_schedule" {
  description = "systemd OnCalendar expression for the backup timer. Ignored unless backup_bucket is set."
  type        = string
  default     = "daily"
}

variable "maxmemory_percent" {
  description = <<-EOT
    Share of the instance's real memory given to Valkey.

    70 suits a gibibyte and up. Drop it on very small nodes — a t4g.nano
    has 512 MiB and the OS takes 200-250 of them, so 70% would price the
    dataset above what is actually free and turn a full resync into an
    OOM kill.
  EOT
  type        = number
  default     = 70
}

variable "maxmemory_policy" {
  description = <<-EOT
    What happens when the instance reaches maxmemory.

    `noeviction` for any fleet carrying a lossless stream — the eventbus
    refuses to start against anything else, because a store that silently
    drops entries under pressure cannot uphold durability. A full instance
    must fail writes loudly instead.

    `allkeys-lru` for a cache, where dropping the coldest key is the point.
  EOT
  type        = string
  default     = "noeviction"
}

variable "create_timeout" {
  description = "How long to wait for the instance to launch. Short values fail fast on InsufficientInstanceCapacity instead of letting the provider retry silently for over an hour."
  type        = string
  default     = "10m"
}

variable "ami_id" {
  description = "AMI to launch. Empty resolves the current Amazon Linux 2023 ARM64 image from its SSM alias, which is the same alias in every region — no copying, no per-region map. Set explicitly to pin, or to swap in a baked image later without touching anything else."
  type        = string
  default     = ""
}

variable "data_volume_gb" {
  description = "Size of the data volume. Valkey is in-memory; this holds the AOF/RDB and logs, so it tracks dataset size rather than memory."
  type        = number
  default     = 8
}

variable "vpc_id" {
  type        = string
  description = "VPC to launch into."
}

variable "subnet_id" {
  type        = string
  description = "Private subnet. Which AZ this lands in IS the availability design — put the master and its promotable replica in different ones."
}

variable "client_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach 6379 and 26379.

    CIDRs rather than security-group ids because these are crossed by
    INTER-REGION peering, where SG references do not work. Keep the ranges
    narrow — the subnets that actually hold callers, not a whole /16.
  EOT
  type        = list(string)
}

variable "dns_zone_id" {
  type        = string
  description = "Private hosted zone to register this node's own hostname in."
}

variable "dns_zone_name" {
  type        = string
  description = "Zone name, used to build the FQDN."
}

variable "tags" {
  type        = map(string)
  description = "Base tags, merged into every resource."
  default     = {}
}
