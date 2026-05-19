output "instance_id" {
  description = "RDS instance identifier."
  value       = aws_db_instance.main.id
}

output "endpoint" {
  description = "RDS endpoint (host:port). Prefer the internal DNS name for app config — this is for debugging."
  value       = aws_db_instance.main.endpoint
}

output "address" {
  description = "RDS hostname (no port). Used as the CNAME target."
  value       = aws_db_instance.main.address
}

output "port" {
  description = "Postgres port (always 5432 unless overridden)."
  value       = aws_db_instance.main.port
}

output "internal_dns_name" {
  description = "Internal DNS hostname for the DB (e.g. `pg.staging.meandr.local`). Use this in app config; survives instance replacements."
  value       = aws_route53_record.pg.fqdn
}

output "security_group_id" {
  description = "SG attached to the DB. Future workloads that need DB access can reference this in their own SG ingress rules."
  value       = aws_security_group.main.id
}

output "secret_arn" {
  description = "Secrets Manager ARN for the master credential JSON blob. Read this from the meandr-api task role."
  value       = aws_secretsmanager_secret.master.arn
}

output "secret_name" {
  description = "Secrets Manager secret name."
  value       = aws_secretsmanager_secret.master.name
}

output "db_name" {
  description = "Initial database created."
  value       = aws_db_instance.main.db_name
}
