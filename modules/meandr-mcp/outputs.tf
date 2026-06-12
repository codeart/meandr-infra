# --- Cluster + service --------------------------------------------------

output "cluster_arn" { value = module.cluster.cluster_arn }
output "cluster_name" { value = module.cluster.cluster_name }
output "proxy_service_name" { value = module.proxy.service_name }
output "task_role_arn" { value = aws_iam_role.task.arn }

# --- NLB ----------------------------------------------------------------

output "nlb_arn" { value = aws_lb.main.arn }
output "nlb_dns_name" { value = aws_lb.main.dns_name }
output "nlb_zone_id" { value = aws_lb.main.zone_id }
output "target_group_arn" { value = aws_lb_target_group.proxy.arn }

# --- Writer Valkey -----------------------------------------------------
#
# Endpoints exposed so the region caller can wire BE (in the primary
# region) to subscribe to this region's streams. Both AWS-internal
# hostnames; consumers connect directly so the cluster's wildcard cert
# verifies cleanly.

output "writer_primary_endpoint" {
  description = "Writer cluster primary endpoint (AWS-internal hostname). Proxy writes counters / streams / locks here; BE consumes streams here too."
  value       = module.writer_valkey.primary_endpoint_address
}

output "writer_reader_endpoint" {
  description = "Writer cluster reader endpoint (AWS-internal hostname). For replica reads if/when num_cache_clusters > 1."
  value       = module.writer_valkey.reader_endpoint_address
}

output "writer_security_group_id" {
  description = "Writer cluster SG ID — needed by cross-region peers if VPC peering is set up later."
  value       = module.writer_valkey.security_group_id
}
