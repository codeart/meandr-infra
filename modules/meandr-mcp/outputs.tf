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

# --- State-plane Valkey ------------------------------------------------
#
# Exposed so the BE in the primary region can subscribe to this region's
# state-plane streams (audit, events) via the be-state-in.<region> name.

output "mcp_state_in_dns" {
  description = "Per-region state-plane reader DNS (e.g. `mcp-state-in.eu-central-1.staging.meandr.local`). Proxy reads counters from this."
  value       = aws_route53_record.mcp_state_in.fqdn
}

output "mcp_state_out_dns" {
  description = "Per-region state-plane writer DNS. Proxy writes counters/streams/locks to this."
  value       = aws_route53_record.mcp_state_out.fqdn
}

output "be_state_in_dns" {
  description = "Per-region state-plane reader for BE (XREAD stream consumers)."
  value       = aws_route53_record.be_state_in.fqdn
}

output "state_endpoint" {
  description = "State-plane primary endpoint address (raw ElastiCache hostname)."
  value       = module.state_valkey.primary_endpoint_address
}

output "state_security_group_id" {
  description = "State-plane SG ID — needed by cross-region peers if VPC peering is set up later."
  value       = module.state_valkey.security_group_id
}
