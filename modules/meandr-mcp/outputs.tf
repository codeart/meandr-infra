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

# --- Event fleet --------------------------------------------------------
#
# Echoed back so the region caller can wire BE — which lives in the
# primary region — to consume this region's outbound streams without
# repeating the record.
#
# The MASTER, not a replica: BE consumes via XREADGROUP, which mutates
# consumer-group state and is refused by a replica.

output "event_writer_endpoint" {
  description = "Master record of this region's event fleet, as given to the proxy. A bootstrap value: both sides discover the master through Sentinel."
  value       = var.event_writer_endpoint
}
