# --- Cluster + service --------------------------------------------------

output "cluster_arn"           { value = module.cluster.cluster_arn }
output "cluster_name"          { value = module.cluster.cluster_name }
output "proxy_service_name"    { value = module.proxy.service_name }
output "task_role_arn"         { value = aws_iam_role.task.arn }

# --- NLB ----------------------------------------------------------------

output "nlb_arn"          { value = aws_lb.main.arn }
output "nlb_dns_name"     { value = aws_lb.main.dns_name }
output "nlb_zone_id"      { value = aws_lb.main.zone_id }
output "target_group_arn" { value = aws_lb_target_group.proxy.arn }

# --- Writer Valkey -----------------------------------------------------
#
# Exposed so the BE in the primary region can subscribe to this region's
# streams (audit, events) via be-redis-in.<region>.

output "mcp_redis_out_dns" {
  description = "Per-region writer DNS — proxy writes counters / streams / locks here. e.g. `mcp-redis-out.eu-central-1.staging.meandr.local`."
  value       = aws_route53_record.mcp_redis_out.fqdn
}

output "be_redis_in_dns" {
  description = "Per-region writer reader DNS — BE consumes streams from here via XREAD."
  value       = aws_route53_record.be_redis_in.fqdn
}

output "writer_endpoint" {
  description = "Writer cluster primary endpoint (raw ElastiCache hostname)."
  value       = module.writer_valkey.primary_endpoint_address
}

output "writer_security_group_id" {
  description = "Writer cluster SG ID — needed by cross-region peers if VPC peering is set up later."
  value       = module.writer_valkey.security_group_id
}
