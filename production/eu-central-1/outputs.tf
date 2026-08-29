output "vpc_id" { value = module.vpc.vpc_id }
output "vpc_cidr_block" { value = module.vpc.vpc_cidr_block }
output "public_subnet_ids" { value = module.vpc.public_subnet_ids }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }

# No internal_ca_secret_arn: the CA is minted in the primary and read here
# from its replica.

# Master RECORDS, not node names — they follow a promotion. Prefer the
# Sentinel sets for anything that connects.
#
# No valkey_config_master: that name is global and the primary owns it.
output "valkey_events_master" { value = module.valkey.fleets["events"].master_hostname }

output "event_stream_writer_endpoint" { value = module.mcp.event_writer_endpoint }

# --- meandr-api (PRIMARY ONLY) -----------------------------------------
#
# Absent. BE and Postgres are central, so an edge exports nothing for them.

# --- Proxy --------------------------------------------------------------

output "mcp_cluster_name" { value = module.mcp.cluster_name }
output "mcp_proxy_service_name" { value = module.mcp.proxy_service_name }
output "mcp_nlb_dns_name" { value = module.mcp.nlb_dns_name }

# --- Storage ------------------------------------------------------------
#
# No archive_bucket: one per environment, and it lives in the primary.

output "payloads_bucket" {
  description = "Request/response bodies. A BUFFER here — replicated into the primary, which is the bucket BE and Athena read."
  value       = module.payloads_bucket.bucket
}

# --- Cross-region -------------------------------------------------------

output "peering_connection_id" { value = module.peering.connection_id }
