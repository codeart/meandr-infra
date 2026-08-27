output "fleets" {
  description = "Per-fleet handles, keyed by fleet name: master_hostname, sentinel_addrs, hostnames, instance_ids."
  value       = module.fleet
}

output "instance_ids" {
  description = "Every node in the region, for the recipes fan-out. Derived, so a fleet cannot silently drop out of it."
  value       = flatten([for f in module.fleet : f.instance_ids])
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.id
}
