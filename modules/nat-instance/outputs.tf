output "network_interface_id" {
  description = "Route target. The instance's primary interface — it changes when the box is replaced, and Terraform updates the route with it. The EIP does not change, so the egress address survives."
  value       = aws_instance.main.primary_network_interface_id
}

output "public_ip" {
  description = "This AZ's egress address. Fixed for the life of the EIP, so it is safe in a customer's allow-list."
  value       = aws_eip.main.public_ip
}

output "instance_id" {
  value = aws_instance.main.id
}

output "capacity_reservation_id" {
  description = "The held slot. Targeted, so only this instance can use it — and only this instance's launch fails if it is gone."
  value       = aws_ec2_capacity_reservation.main.id
}

output "security_group_id" {
  value = aws_security_group.main.id
}
