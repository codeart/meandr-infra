variable "cidr_block" {
  description = "VPC CIDR. Pick a /16 from RFC1918 that doesn't overlap any other env's VPC — required for future VPC peering safety. Staging: 10.10.0.0/16; production: 10.20.0.0/16."
  type        = string
}

variable "azs" {
  description = "List of AZs to span. Each gets one public + one private subnet. Use a single AZ for cost-sensitive envs (staging); multi-AZ for HA in production."
  type        = list(string)
}

variable "enable_nat" {
  description = "If true, private subnets get a route to the internet — by gateway or by instance, per `nat_mode`. Set false for envs with no running workloads (e.g. production before launch); they cost $0/month for the VPC."
  type        = bool
  default     = true
}

variable "nat_mode" {
  description = <<-EOT
    How private subnets reach the internet. `gateway` is the managed
    regional NAT gateway; `instance` is our own EC2 NAT.

    The trade is a fixed ~$33-38/month per AZ address against ~$3.50 for a
    t4g.nano, measured against peaks of 3.5 Mbps and 402 packets/sec. What
    the gateway buys for the difference is absorbing instance faults
    invisibly; an instance is a box that can hang, and a reboot alarm is a
    slower answer than a managed service.

    This chooses only what the DEFAULT ROUTE points at. Both can exist at
    once — `nat_pinned_azs` and `nat_instance_azs` govern existence — which
    is what makes the cutover reversible: flip the route, and the gateway is
    still there, with its address, to flip back to.

    Retiring the gateway is a SEPARATE, later step (empty `nat_pinned_azs`)
    and it is the irreversible one: the EIP is released, and a rebuild gets
    a different address that anything holding an allow-list has to be told
    about.
  EOT
  type        = string
  default     = "gateway"

  validation {
    condition     = contains(["gateway", "instance"], var.nat_mode)
    error_message = "nat_mode must be \"gateway\" or \"instance\"."
  }
}

variable "nat_instance_azs" {
  description = <<-EOT
    AZs that get a NAT instance when `nat_mode = "instance"`. Each needs a
    public subnet in that AZ, so every entry must also appear in `azs`.

    ONE entry serves the whole VPC: the single private route table points
    at it, exactly as a one-AZ-pinned gateway does today. More than one
    currently buys the extra instances and addresses but NOT per-AZ egress
    — that needs the private route table split per AZ, and the S3 and
    DynamoDB gateway endpoints re-pointed at every one of them.

    Checked in `terraform_data.nat_instance_guard`, not by a validation
    block: those cannot see another variable until Terraform 1.9, and this
    repo pins 1.5.
  EOT
  type        = list(string)
  default     = []
}

variable "nat_instance_type" {
  description = "Instance type for NAT instances. Graviton only; the AMI is arm64."
  type        = string
  default     = "t4g.nano"
}

variable "nat_alarm_topic_arns" {
  description = "Where a NAT instance's conntrack alarm goes. Empty leaves it visible but silent, which is the right default for staging and the wrong one for production."
  type        = list(string)
  default     = []
}

variable "nat_pinned_azs" {
  description = <<-EOT
    AZs the regional NAT gateway holds an address in. One EIP each.

    It SERVES every AZ regardless — an AZ with no address of its own is
    processed by one that has it. So this is a cost and IP-stability
    control, not a coverage one: pin the AZs that actually egress, and let
    the rest ride.

    Supplying this list puts the gateway in MANUAL mode, which disables
    auto-expansion for good. That is deliberate. In automatic mode AWS
    adds an address in any AZ where it detects an ENI, so the egress IP
    set — and the bill — change on their own as workloads move, and a
    customer's firewall allow-list silently stops being complete.

    Staging pins one AZ; production pins two, so losing a zone leaves an
    address behind.

    EMPTY means NO GATEWAY. It is also how a gateway is finally retired
    after `nat_mode = "instance"` has been proven — until then the gateway
    stays, unrouted, as somewhere the route can be moved back to in seconds
    while keeping its address.

    This list no longer selects AUTOMATIC mode, which AWS offers and we
    never want: it adds an address in any AZ where it finds an ENI, so the
    egress set and the bill change on their own and a customer's allow-list
    silently stops being complete. Manual is the only mode expressible here.
  EOT
  type        = list(string)
  default     = []
}

variable "existing_zone_id" {
  description = <<-EOT
    Zone id of the environment's private hosted zone. EMPTY creates it —
    which exactly one region per environment should do.

    Every later region passes the first region's zone id and ASSOCIATES
    with it. A region that creates its own zone of the same name is the
    collision this exists to prevent: names resolve locally, so a node
    told to replicate from another region's host silently attaches to
    whatever shares that name at home. No error, healthy-looking link,
    wrong master.

    Sentinel raises the stakes — it answers with hostnames, so every name
    it can hand out has to mean the same node from anywhere.
  EOT
  type        = string
  default     = ""
}

variable "internal_dns_zone" {
  description = <<-EOT
    Name of the Route 53 private hosted zone created for this VPC. Used for
    internal service discovery — RDS, ElastiCache, Valkey and friends live
    here. Convention: `<env>.meandr.internal` (e.g. `staging.meandr.internal`).

    `.internal`, not `.local`. RFC 6762 reserves `.local` for mDNS, so a
    resolver is entitled to answer those from multicast rather than from
    us — and our own dev machines already wildcard `*.meandr.local` to
    127.0.0.1. ICANN reserved `.internal` in 2024 for exactly this: never
    delegated, guaranteed NXDOMAIN in public DNS, so a query that escapes
    fails instead of leaking a hostname or resolving to a stranger.
  EOT
  type        = string
}

variable "env" {
  description = <<-EOT
    Environment, used only to qualify Name tags.

    Without it every region in every account calls its VPC "Main VPC",
    which is ambiguous in any view that spans regions or accounts —
    Resource Explorer, tag-based cost reports, a console with several
    accounts open. The region is already carried by the resource itself;
    the environment is not.

    Separated by " - " and not parentheses: ELB tag values accept only
    `\p{L}\p{Z}\p{N}_.:/=+-@`, and reject a bracket mid-apply rather than
    at plan.
  EOT
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}
