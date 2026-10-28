output "security_group_id" {
  description = "The model nodes' group: an edge's root admits the other region's gateway on it."
  value       = aws_security_group.node.id
}

output "mirror_url" {
  description = "Where TEI's images are copied, tags as on ghcr.io (cpu-arm64-<version>, turing-<version>, 89-<version>), and ours (turing-arm64-<version>)."
  value       = aws_ecr_repository.tei.repository_url
}

output "models_bucket" {
  description = "Where the model's files are copied, under its Hugging Face id."
  value       = aws_s3_bucket.models.id
}

output "primary_group_name" {
  value = aws_autoscaling_group.primary.name
}

output "gateway" {
  description = "What hosted machines' agents dial: the gateway's URL, the certificate name they check, and its zone, which the region's hosted VPC must be associated with."
  value = {
    url     = "https://embed.${local.gateway_zone}:${local.gateway_port}"
    name    = local.cert_name
    zone_id = aws_service_discovery_private_dns_namespace.gateway.hosted_zone
  }
}

output "gateway_cidr" {
  description = "The subnet the gateway runs in, which the other region's model nodes admit."
  value       = data.aws_subnet.zone_a.cidr_block
}

output "cluster_name" {
  value = module.cluster.cluster_name
}

output "gateway_service_name" {
  value = module.gateway.service_name
}

output "queue_instance_id" {
  value = module.queue.instance_id
}

output "interrupt_templates" {
  description = "FIS experiment template ids: later (rebalance hint 5 minutes ahead) and now (2-minute notice)."
  value       = { for k, t in aws_fis_experiment_template.gpu_interrupt : k => t.id }
}
