# The RDS certificate authorities, vendored per region.
#
# `sslmode=verify-full` needs a root the operating system does not carry:
# the RDS roots are a PRIVATE Amazon PKI, self-signed and absent from
# every public trust store. Without this, verification cannot succeed no
# matter what the base image ships.
#
# Vendored rather than fetched, so neither a plan nor a deploy depends on
# an endpoint outside our own artifacts — the same rule the Valkey source
# follows.
#
# REGIONAL, not the global bundle: a task only ever reaches RDS in its own
# region, and the global bundle is 165 KB against a 64 KB task-definition
# budget. Three certificates per region, ~4.6 KB.
#
# A module rather than a file two directories up, because both
# ecs-fargate-service and ecs-oneoff-task need it and a `../sibling/files`
# path breaks silently the day either module moves.

locals {
  path = "${path.module}/files/rds-${var.region}-bundle.pem"
}

variable "region" {
  description = "Region whose bundle to load. A region with no vendored bundle fails at PLAN — the same discipline as pinning a source version, and far better than a task that starts and cannot verify."
  type        = string
}

output "pem" {
  description = "PEM bundle contents, for injection into a task definition. Public data — a certificate, not a secret."
  value       = file(local.path)
}

output "filename" {
  description = "Conventional on-task path for the bundle, so every consumer agrees on where it lands."
  value       = "/var/run/rds/ca.pem"
}

output "dir" {
  description = "Directory the bundle is mounted at."
  value       = "/var/run/rds"
}
