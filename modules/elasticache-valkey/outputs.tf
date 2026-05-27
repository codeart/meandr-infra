output "replication_group_id" {
  description = "ElastiCache replication group identifier."
  value       = aws_elasticache_replication_group.main.id
}

output "primary_endpoint_address" {
  description = "Primary endpoint hostname (no port). Use the internal DNS name in app config instead — survives endpoint changes."
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "reader_endpoint_address" {
  description = "Reader endpoint hostname. Same as primary when num_cache_clusters = 1. Round-robins across replicas when > 1."
  value       = aws_elasticache_replication_group.main.reader_endpoint_address
}

output "port" {
  description = "Valkey port (always 6379)."
  value       = aws_elasticache_replication_group.main.port
}

# DNS hostnames are caller-owned (each app uses its own prefix). The
# raw endpoint outputs above are what the caller uses to point Route53
# CNAMEs at.

output "security_group_id" {
  description = "SG attached to the cluster. Workloads needing cache access can reference this in their own SG ingress rules."
  value       = aws_security_group.main.id
}

output "transit_encryption_enabled" {
  description = "Whether TLS-in-transit is on (true => GD-eligible)."
  value       = aws_elasticache_replication_group.main.transit_encryption_enabled
}

output "engine_version" {
  description = "Actual engine version provisioned (Valkey)."
  value       = aws_elasticache_replication_group.main.engine_version_actual
}
