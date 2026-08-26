output "listener_arn" {
  description = <<-EOT
    What a REGION attaches to. Each region declares its own
    aws_globalaccelerator_endpoint_group against this arn, pointing at its
    own NLB — so adding or removing a region never edits the accelerator,
    and this module holds no list of them.

    Same inversion as aws_kms_replica_key and aws_dynamodb_table_replica:
    the shared thing is made attachable, and the attaching is declared
    where the attachment lives.
  EOT
  value       = aws_globalaccelerator_listener.main.id
}

output "dns_name" {
  description = "Accelerator DNS name. The wildcard record already aliases to it; this is for diagnostics."
  value       = aws_globalaccelerator_accelerator.main.dns_name
}

output "static_ips" {
  description = <<-EOT
    The two anycast addresses. Stable for the accelerator's lifetime, which
    is what makes them safe to hand a customer for an allow-list.

    These are also what the proxy's SSRF dial guard must load as its self
    IPs (SetSelfIPs) — without that, a tenant could name our own front door
    as an upstream and have the proxy call itself.
  EOT
  value       = flatten(aws_globalaccelerator_accelerator.main.ip_sets[*].ip_addresses)
}
