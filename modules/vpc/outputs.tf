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
  description = "The environment's private hosted zone ID — created here in the first region, passed in and associated in every later one. Downstream modules add records without caring which."
  value       = var.existing_zone_id != "" ? var.existing_zone_id : aws_route53_zone.internal[0].zone_id
}

output "internal_dns_zone_name" {
  description = "Internal DNS zone name (e.g. `staging.meandr.internal`). Use as a suffix when constructing record names."
  value       = var.internal_dns_zone
}

output "azs" {
  description = "List of AZs this VPC spans (passed-through from input for convenience)."
  value       = var.azs
}

output "nat_enabled" {
  description = "Whether egress from private subnets is provisioned at all. Downstream modules use it to know whether they can reach the internet."
  value       = var.enable_nat
}

# For a recipes runner: these are ordinary SSM-managed nodes, so they take
# the same once-per-node changes the Valkey fleets do. Paired with
# nat_recipes_dir, so the set and the nodes come from one place.
output "nat_instance_ids" {
  description = "NAT instances in this VPC, empty when no AZ is listed in nat_instance_azs."
  value       = [for az in var.nat_instance_azs : module.nat_instance[az].instance_id]
}

output "nat_recipes_dir" {
  description = "The NAT recipe set, for modules/ssm-recipes. Empty today — anything a NAT needs at boot belongs in user-data, and a recipe is for changing a RUNNING box without replacing it."
  value       = "${path.module}/../nat-instance/recipes"
}

# The set a customer allow-lists. Both modes are enumerated here so the
# answer does not depend on which one is in effect.
output "nat_egress_ips" {
  description = "Every address this VPC egresses from. Fixed by design — manual-mode pinning on the gateway, an EIP per instance otherwise."
  value = var.nat_mode == "instance" ? [
    for az in var.nat_instance_azs : module.nat_instance[az].public_ip
    ] : [
    for e in aws_eip.regional_nat : e.public_ip
  ]
}

output "s3_endpoint_id" {
  description = "S3 gateway endpoint ID. Useful for bucket policies that restrict access to traffic arriving via this VPC (aws:SourceVpce)."
  value       = aws_vpc_endpoint.s3.id
}

output "dynamodb_endpoint_id" {
  description = "DynamoDB gateway endpoint ID. Same use as s3_endpoint_id — table policies can pin to aws:SourceVpce."
  value       = aws_vpc_endpoint.dynamodb.id
}

# Route table ids, so another state file can add a peering route without
# an inline block here fighting it. See the note above aws_route_table.
output "public_route_table_id" {
  description = "Public route table. Extend with aws_route from the caller; never with an inline route here."
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "The SHARED private route table. Serves every AZ not listed in per_az_route_tables — so it may serve none. A peering route needs private_route_table_ids, not this."
  value       = aws_route_table.private.id
}

# What a peering route must reach: every private table, or the AZs that
# moved off the shared one lose the cross-region path silently.
output "private_route_table_ids" {
  description = "Every private route table, shared and per-AZ. This is what a cross-region peering route belongs in — all of them."
  value       = local.private_route_table_ids
}

output "private_az_route_table_ids" {
  description = "Per-AZ private tables only, keyed by AZ. Empty until an AZ is listed in per_az_route_tables."
  value       = { for az in var.per_az_route_tables : az => aws_route_table.private_az[az].id }
}
