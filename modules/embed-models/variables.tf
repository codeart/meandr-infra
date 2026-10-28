variable "env" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Where the CPU node, the gateway and its queue run (the gateway and queue in the first)."
  type        = list(string)
}

variable "gpu_subnet_ids" {
  description = "Every private subnet: each GPU group keeps those whose zone offers its types."
  type        = list(string)
}

variable "models" {
  description = "The CPU node's type (none without), the T4G group's types in order of preference, the fallback's (none without; one region has it), the embedding model and the reranker (Hugging Face ids; none without), TEI's version as the mirror tags it, and the release our T4G build compiles (the primary's only)."
  type = object({
    cpu_type       = optional(string)
    primary_types  = list(string)
    fallback_types = optional(list(string), [])
    model          = string
    reranker       = optional(string)
    tei_version    = string
    tei_release    = optional(string)
  })
}

variable "mirror_source" {
  description = "An edge's: the region whose mirror and model bucket its own are copied from. Null in the primary, which builds."
  type        = object({ region = string })
  default     = null
}

variable "peer_regions" {
  description = "Other regions running this module, whose GPU nodes stand in for this one's."
  type        = list(string)
  default     = []
}

variable "region_code" {
  description = "The region's code (`use1`): the queue node is `<code>a`, as the fleets' nodes are, since its IAM role is account-wide."
  type        = string
}

variable "gateway" {
  description = "The gateway's image (meandr-embed-gw, from the region's ECR replica) and its logs."
  type = object({
    image              = string
    log_level          = string
    log_retention_days = number
  })
}

variable "machines" {
  description = "Hosted machines that may dial the gateway: every region's fleet CIDR, and the regions their proofs are signed in."
  type = object({
    cidrs   = list(string)
    regions = list(string)
  })
}

variable "internal_dns_zone" {
  description = "The env's internal zone: the queue node's record, and the parent of the gateway's own zone."
  type = object({
    id   = string
    name = string
  })
}

variable "tls_secret_arn" {
  description = "internal-pki's embed secret: ca_crt, embed_crt, embed_key."
  type        = string
}

variable "redis" {
  description = "The fleets the gateway reads app records from and writes usage to, their AUTH and client keypair, and the node keypair its queue serves."
  type = object({
    auth_secret_arn   = string
    client_secret_arn = string
    node_secret_arn   = string
    config            = object({ sentinel_addrs = list(string), master = string })
    events            = object({ sentinel_addrs = list(string), master = string })
  })
}

variable "valkey" {
  description = "The fleets' Valkey build for the queue's node: version, vendored tarball and the stack's artifacts bucket."
  type = object({
    version       = string
    source_path   = string
    source_bucket = string
  })
}

variable "parked" {
  description = "The env's `parked`: no nodes."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
