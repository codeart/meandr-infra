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

# --- Event-stream Valkey -----------------------------------------------
#
# Endpoints exposed so the region caller can wire BE (in the primary
# region) to consume this region's outbound streams. AWS-internal
# hostnames; consumers connect directly so the cluster's wildcard cert
# verifies cleanly.
#
# Only the writer (primary) endpoint is exposed: BE consumes streams via
# XREADGROUP, which is a write op and so needs the primary anyway. The
# reader endpoint of this cluster has no current consumer.

output "event_writer_endpoint" {
  description = "Writer (primary) endpoint of `meandr-event-stream`. AWS-internal hostname. Proxy uses it for XADD on outbound/audit streams + rate-limit counters; BE uses it for XREADGROUP consumption."
  value       = module.event_stream.primary_endpoint_address
}

output "event_stream_security_group_id" {
  description = "Event-stream cluster SG ID — needed by cross-region peers if VPC peering is set up later."
  value       = module.event_stream.security_group_id
}
