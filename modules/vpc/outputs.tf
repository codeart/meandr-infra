output "vpc_id" {
  description = "VPC ID. Downstream modules (RDS, ElastiCache, ECS) need this."
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "VPC CIDR. Used by security groups that allow intra-VPC traffic."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, in the order of var.azs. Place NAT Gateway, ALB, bastion (if any) here."
  value       = [for az in var.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "Private subnet IDs, in the order of var.azs. Place ECS tasks, RDS, ElastiCache, EC2 Redis here."
  value       = [for az in var.azs : aws_subnet.private[az].id]
}

output "internal_dns_zone_id" {
  description = "Route 53 private hosted zone ID. Downstream modules add records here."
  value       = aws_route53_zone.internal.zone_id
}

output "internal_dns_zone_name" {
  description = "Internal DNS zone name (e.g. `staging.meandr.internal`). Use as a suffix when constructing record names."
  value       = aws_route53_zone.internal.name
}

output "azs" {
  description = "List of AZs this VPC spans (passed-through from input for convenience)."
  value       = var.azs
}

output "nat_enabled" {
  description = "Whether NAT Gateway is provisioned. Useful for downstream modules to know whether internet egress is available from private subnets."
  value       = var.enable_nat
}

output "s3_endpoint_id" {
  description = "S3 gateway endpoint ID. Useful for bucket policies that restrict access to traffic arriving via this VPC (aws:SourceVpce)."
  value       = aws_vpc_endpoint.s3.id
}

output "dynamodb_endpoint_id" {
  description = "DynamoDB gateway endpoint ID. Same use as s3_endpoint_id — table policies can pin to aws:SourceVpce."
  value       = aws_vpc_endpoint.dynamodb.id
}
