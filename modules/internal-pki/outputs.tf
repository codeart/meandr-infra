output "node_secret_arn" {
  description = "Secret holding ca_crt + node_crt + node_key. For valkey-node instances ONLY — it contains the private key."
  value       = aws_secretsmanager_secret.node.arn
}

output "ca_secret_arn" {
  description = "Secret holding just the CA certificate. What proxy and BE read to verify the fleet; safe to grant widely, since it carries no key."
  value       = aws_secretsmanager_secret.ca.arn
}

output "ca_cert_pem" {
  description = "The CA certificate itself, for callers that would rather inject it than fetch it at runtime. Public — it is a certificate, not a key."
  value       = tls_self_signed_cert.ca.cert_pem
}

output "client_secret_arn" {
  description = "Client TLS material for proxy and BE: ca_crt, client_crt, client_key. Required now that nodes run tls-auth-clients yes."
  value       = aws_secretsmanager_secret.client.arn
}

output "mesh_secret_arn" {
  description = "Proxy mesh TLS material: ca_crt, mesh_crt, mesh_key. Server + client auth, for proxy-to-proxy intercom. Contains a private key — proxy tasks only."
  value       = aws_secretsmanager_secret.mesh.arn
}

output "mesh_server_name" {
  description = "The single name every proxy pins as TLS ServerName when dialing a peer. Not resolvable and not meant to be — peers are dialed by the address they publish in their heartbeat."
  value       = local.mesh_name
}
