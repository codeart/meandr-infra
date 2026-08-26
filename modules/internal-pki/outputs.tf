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
