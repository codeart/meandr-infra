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

# --- Cert ---------------------------------------------------------------

output "certificate_arn" { value = module.cert.certificate_arn }

# --- Writer Valkey -----------------------------------------------------
#
# Exported so other regions / the BE can reach this region's writer.
# (BE in primary region subscribes to streams on each region's local writer.)

output "writer_internal_dns_name" {
  description = "Writer Valkey internal DNS name in this region (e.g. `redis-writer.staging.meandr.local`)."
  value       = module.writer.internal_dns_name
}

output "writer_endpoint" {
  description = "Writer Valkey primary endpoint address."
  value       = module.writer.primary_endpoint_address
}

output "writer_security_group_id" {
  description = "Writer Valkey SG ID — needed by cross-region peers if VPC peering is set up later."
  value       = module.writer.security_group_id
}
