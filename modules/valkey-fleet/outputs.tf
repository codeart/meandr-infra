output "master_hostname" {
  description = "The fleet's master record name. A bootstrap address only — clients follow Sentinel, which moves on failover without waiting out a TTL."
  value       = module.a.master_hostname
}

output "sentinel_addrs" {
  description = "This fleet's three Sentinel endpoints, ready to hand a client. Callers list their OWN region first: discovery walks the list in order and is not latency-aware."
  value = [
    "${module.a.hostname}:26379",
    "${module.b.hostname}:26379",
    "${module.c.hostname}:26379",
  ]
}

output "hostnames" {
  description = "Per-node stable names, keyed a/b/c. Reaches a specific box; never use one to find the master."
  value = {
    a = module.a.hostname
    b = module.b.hostname
    c = module.c.hostname
  }
}

output "instance_ids" {
  description = "For SSM sessions, recipes and deliberate failover drills."
  value       = [module.a.instance_id, module.b.instance_id, module.c.instance_id]
}
