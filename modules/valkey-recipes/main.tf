# Recipes: ordered, once-per-node changes applied to RUNNING instances.
#
# The node's user-data is hash-pinned, so editing it replaces the
# instance. That is correct for anything identity-level and intolerable
# for a logrotate file. Recipes are the other half: numbered scripts
# delivered over SSM, each applied exactly once per node and recorded in
# a ledger on the node itself.
#
# They are NEVER embedded in user-data. That is the whole point — adding
# one can never produce a plan that rebuilds the fleet.
#
# The cost is that this is imperative, and Terraform cannot see inside a
# node to know whether a recipe took. The ledger is the source of truth,
# and the runner reports per-node so a partial rollout is visible rather
# than assumed.

locals {
  dir = var.recipes_dir != "" ? var.recipes_dir : "${path.module}/recipes"

  # Sorted so filename order IS apply order — 001 before 002, forever.
  files = sort(tolist(fileset(local.dir, "*.sh")))

  # Content-addressed: renaming a recipe or editing one byte re-triggers.
  # Hashing CONTENT rather than names means a fixed typo actually ships.
  manifest = join("\n", [for f in local.files : "${f}:${filesha256("${local.dir}/${f}")}"])
}

resource "null_resource" "recipes" {
  triggers = {
    # A new or edited recipe fans out to every existing node.
    manifest = sha256(local.manifest)

    # A new node re-runs the fan-out so it picks up the backlog. Sorted so
    # a caller reordering its module blocks is not a change.
    instances = join(",", sort(var.instance_ids))
  }

  # Fails loudly and leaves the resource tainted, so the next apply
  # retries rather than recording a rollout that did not happen.
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/files/apply-recipes.sh"

    environment = {
      RECIPES_DIR   = local.dir
      RECIPE_FILES  = join(" ", local.files)
      INSTANCE_IDS  = join(" ", sort(var.instance_ids))
      AWS_PROFILE   = var.aws_profile
      AWS_REGION    = var.aws_region
      WAIT_SECONDS  = tostring(var.timeout_seconds)
      REGISTER_WAIT = tostring(var.register_timeout_seconds)
    }
  }
}