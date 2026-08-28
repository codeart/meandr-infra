# THE ONLY FILE THAT DIFFERS BETWEEN ENVIRONMENTS.
#
# Onboarding an environment is: copy the directory, edit this file, adjust
# backend.tf's key. main.tf should stay byte-identical across accounts.

provider "aws" {
  region  = "us-east-1"
  profile = "meandr-production"
}

# Global Accelerator's control plane exists ONLY in us-west-2, whatever
# region the endpoints live in. Nothing about the accelerator runs there.
provider "aws" {
  alias   = "usw2"
  region  = "us-west-2"
  profile = "meandr-production"
}

# The public zones live in the Shared account.
provider "aws" {
  alias   = "shared"
  region  = "eu-central-1"
  profile = "meandr-shared"
}

locals {
  env        = "production"
  account_id = "393686273464"

  # Public apex this environment's proxies serve.
  proxy_apex = "meandr.io"

  # Every region running a proxy. Each also needs a provider alias and a
  # self_ips block below, so this file is where the list has to live;
  # publishing it keeps CI from enumerating regions a second time.
  regions = ["us-east-1"]

  # Operational alarms, not billing — the budget topic keeps aws-billing.
  alert_emails = ["aws-prd@meandr.com"]

  # Production trusts main only, and the `production` GH Environment, whose
  # required reviewers make a deploy need both a green main AND a human.
  allowed_refs            = ["refs/heads/main"]
  allowed_gh_environments = ["production"]

  # Tiered: 50% is the early heads-up, 100% the holy-shit signal, without
  # alerting on every small move. ACTUAL-only: AWS rejects FORECASTED on
  # DAILY. Anomaly threshold is higher than staging's because production
  # has real traffic-driven variation.
  budget_usd        = 100
  budget_thresholds = [50, 75, 95, 100]
  anomaly_usd       = 20
}

# --- Per-region SSM ------------------------------------------------------
#
# One alias and one block per region. SSM parameters are regional with no
# replication, and a resource's provider must be a STATIC reference — so
# this cannot be a loop over local.regions.
#
# No alias here: the only region is this stack's own, so the default
# provider serves it. A second region adds an alias and a block, as
# account-staging has for us-east-1.

resource "aws_ssm_parameter" "self_ips_use1" {
  name  = local.self_ips_param
  type  = "StringList"
  value = join(",", module.global_accelerator.static_ips)
  tags  = local.account_tags
}

# --- Read-only observer for the AWS MCP server --------------------------
#
# ABSENT, deliberately. Staging's observer carries ReadOnlyAccess, which
# can read DynamoDB items and S3 objects — captured payloads included. That
# is an accepted trade there and would not be here. Production gets its own
# user with a policy narrowed to describe-and-metrics when it needs one,
# and it is the only static credential in the estate either way.
