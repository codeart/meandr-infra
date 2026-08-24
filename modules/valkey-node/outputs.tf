output "instance_id" {
  description = "EC2 instance id — for SSM sessions and for targeting a deliberate failover test."
  value       = aws_instance.main.id
}

output "private_ip" {
  value       = aws_instance.main.private_ip
  description = "Private IP. Prefer the hostname; this is here for security-group rules and debugging."
}

output "hostname" {
  description = "This node's stable private DNS name. Points at THIS node whatever its current role — use it to reach a specific box, never to find the master."
  value       = aws_instance.main.private_ip != "" ? local.hostname : ""
}

output "master_hostname" {
  description = <<-EOT
    The name that follows this FLEET's master through failover, for clients
    and replicas. Owned by Sentinel's reconfig script, not by Terraform —
    the record has to move on promotion, and an apply putting it back would
    point every writer at a demoted node.

    Fleet-scoped under the family subdomain: `config-master.valkey.<zone>`,
    `events-master.valkey.<zone>`. Two fleets sharing one master record
    would each fail the other over.
  EOT
  value       = local.master_record
}

output "security_group_id" {
  description = "So a caller can widen access without reaching into the module."
  value       = aws_security_group.main.id
}

output "bootstrap_role" {
  description = "The bootstrap tie-break this node was given. NOT what it booted as, and not its current role — the boot role is derived from the master record, and Sentinel owns it thereafter."
  value       = var.role
}
