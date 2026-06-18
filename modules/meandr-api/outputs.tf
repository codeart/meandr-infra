# --- Cluster + IAM ------------------------------------------------------

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = module.cluster.cluster_arn
}

output "cluster_name" {
  description = "ECS cluster name. Used in `aws ecs ...` CLI commands."
  value       = module.cluster.cluster_name
}

output "task_role_arn" {
  description = "Task IAM role ARN — the runtime identity Rails code runs as."
  value       = aws_iam_role.task.arn
}

# --- Services -----------------------------------------------------------

output "puma_service_name"    { value = module.puma.service_name }
output "jobs_service_name"    { value = module.jobs.service_name }
output "ingest_service_name"  { value = module.ingest.service_name }
output "migrate_task_family"  { value = module.migrate.task_definition_family }

# --- Networking / ALB ---------------------------------------------------

output "alb_arn"          { value = aws_lb.main.arn }
output "alb_dns_name"     { value = aws_lb.main.dns_name }
output "alb_zone_id"      { value = aws_lb.main.zone_id }
output "alb_security_group_id" { value = aws_security_group.alb.id }
output "worker_security_group_id" { value = aws_security_group.worker.id }
output "puma_security_group_id"   { value = aws_security_group.puma.id }

# --- Hostname + cert ---------------------------------------------------

output "hostname"        { value = var.hostname }
output "certificate_arn" { value = module.cert.certificate_arn }

# --- Data tier ---------------------------------------------------------

output "rds_endpoint"           { value = module.rds.endpoint }
output "rds_internal_dns_name"  { value = module.rds.internal_dns_name }
output "rds_secret_arn"         { value = module.rds.secret_arn }
output "rds_db_name"            { value = module.rds.db_name }

# --- Secrets ----------------------------------------------------------

output "rails_master_key_arn" {
  description = "Rails master key secret ARN — operator populates the value from config/credentials/<env>.key after first apply."
  value       = aws_secretsmanager_secret.rails_master_key.arn
}

# --- For run-task invocation ------------------------------------------

output "private_subnet_ids" {
  description = "Pass-through — needed by CI to run the migrate task."
  value       = var.private_subnet_ids
}
