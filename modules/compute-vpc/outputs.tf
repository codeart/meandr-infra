output "vpc_id" { value = aws_vpc.main.id }
output "vpc_cidr" { value = aws_vpc.main.cidr_block }

# az letter -> subnet id, in the placement-priority order the BE's Fleet
# overrides are built from (hosted_nodes.md §4).
output "private_subnet_ids" { value = { for az, s in aws_subnet.private : az => s.id } }

output "node_security_group_id" { value = aws_security_group.node.id }
# arch -> launch template, the pair the BE's Fleet call picks from.
output "launch_template_ids" { value = { for a, lt in aws_launch_template.node : a => lt.id } }
output "cluster_name" { value = aws_ecs_cluster.hosted.name }
output "cluster_arn" { value = aws_ecs_cluster.hosted.arn }
output "task_execution_role_arn" { value = aws_iam_role.task_execution.arn }
output "instance_profile_arn" { value = aws_iam_instance_profile.node.arn }
output "nat_public_ip" { value = module.nat.public_ip }
output "nat_instance_id" { value = module.nat.instance_id }
output "peering_connection_id" { value = aws_vpc_peering_connection.main.id }
