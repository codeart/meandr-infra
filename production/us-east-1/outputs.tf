output "vpc_id" { value = module.vpc.vpc_id }
output "vpc_cidr_block" { value = module.vpc.vpc_cidr_block }
output "public_subnet_ids" { value = module.vpc.public_subnet_ids }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }

# The environment's internal root, for consumers with no Valkey bundle to
# take ca_crt from.
output "internal_ca_secret_arn" {
  description = "Secrets Manager ARN of the environment internal root CA (public cert only)."
  value       = module.internal_pki.ca_secret_arn
}

# Master RECORDS, not node names — they follow a promotion. Prefer the
# Sentinel sets for anything that connects; these are for humans and for a
# second region's bootstrap.
output "valkey_config_master" { value = module.valkey.fleets["config"].master_hostname }
output "valkey_events_master" { value = module.valkey.fleets["events"].master_hostname }
output "valkey_api_master" { value = module.valkey.fleets["api"].master_hostname }

output "event_stream_writer_endpoint" { value = module.mcp.event_writer_endpoint }

# --- meandr-api (PRIMARY ONLY) -----------------------------------------

output "hostname" { value = module.api.hostname }
output "alb_dns_name" { value = module.api.alb_dns_name }
output "cluster_name" { value = module.api.cluster_name }
output "puma_service_name" { value = module.api.puma_service_name }
output "jobs_service_name" { value = module.api.jobs_service_name }
output "ingest_service_name" { value = module.api.ingest_service_name }
output "migrate_task_family" { value = module.api.migrate_task_family }
output "worker_sg_id" { value = module.api.worker_security_group_id }

# --- Proxy --------------------------------------------------------------

output "mcp_cluster_name" { value = module.mcp.cluster_name }
output "mcp_proxy_service_name" { value = module.mcp.proxy_service_name }
output "mcp_nlb_dns_name" { value = module.mcp.nlb_dns_name }

# --- Storage ------------------------------------------------------------

output "archive_bucket" {
  description = "Calls + actions Parquet. The only bucket Athena scans. PRIMARY ONLY."
  value       = one(module.archive_bucket[*].bucket)
}

output "payloads_bucket" {
  description = "Request/response bodies. Written by the proxy, read by ranged GET; never scanned."
  value       = module.payloads_bucket.bucket
}
