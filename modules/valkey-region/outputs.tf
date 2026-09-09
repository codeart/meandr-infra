output "fleets" {
  description = "Per-fleet handles, keyed by fleet name: master_hostname, sentinel_addrs, hostnames, instance_ids."
  value       = module.fleet
}

output "instance_ids" {
  description = "Every node in the region, for the recipes fan-out. Derived, so a fleet cannot silently drop out of it."
  value       = flatten([for f in module.fleet : f.instance_ids])
}

# Paired with instance_ids deliberately: a caller takes both from here, so
# a recipe set and the nodes it reaches are chosen in one place.
output "recipes_dir" {
  description = "This fleet's recipe set, for modules/ssm-recipes."
  value       = "${path.module}/recipes"
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.id
}
