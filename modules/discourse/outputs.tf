output "public_ip" {
  description = "The forum's only public address — the NAT's EIP, which survives an instance replacement."
  value       = module.nat.public_ip
}

output "hostname" {
  value = var.hostname
}

output "app_instance_id" {
  description = "Reach it with `aws ssm start-session --target <id>` — there is no SSH."
  value       = aws_instance.app.id
}

output "smtp_secret_name" {
  description = "Put the Postmark server token here before first boot: `aws secretsmanager put-secret-value --secret-id <name> --secret-string <token>`."
  value       = aws_secretsmanager_secret.smtp.name
}

output "db_endpoint" {
  value = module.db.endpoint
}

output "valkey_hostname" {
  value = aws_route53_record.valkey_master.name
}

output "uploads_bucket" {
  value = aws_s3_bucket.uploads.bucket
}

output "backups_bucket" {
  value = aws_s3_bucket.backups.bucket
}
