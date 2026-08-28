# THE ONLY FILE THAT DIFFERS BETWEEN ENVIRONMENTS.
#
# Onboarding an environment is: copy the directory, edit this file, adjust
# backend.tf's key. main.tf should stay byte-identical across accounts.

provider "aws" {
  region  = "eu-central-1"
  profile = "meandr-staging"
}

# Global Accelerator's control plane exists ONLY in us-west-2, whatever
# region the endpoints live in. Nothing about the accelerator runs there.
provider "aws" {
  alias   = "usw2"
  region  = "us-west-2"
  profile = "meandr-staging"
}

# The public zones live in the Shared account.
provider "aws" {
  alias   = "shared"
  region  = "eu-central-1"
  profile = "meandr-shared"
}

locals {
  env        = "staging"
  account_id = "259534890849"

  # Public apex this environment's proxies serve.
  proxy_apex = "meandr.live"

  # Every region running a proxy. Each also needs a provider alias and a
  # self_ips block below, so this file is where the list has to live;
  # publishing it keeps CI from enumerating regions a second time.
  regions = ["eu-central-1", "us-east-1"]

  # Operational alarms, not billing — the budget topic keeps aws-billing.
  alert_emails = ["aws-stg@meandr.com"]

  # Staging trusts develop as well as main; the GH Environment subject is
  # sent instead of the ref one when a job sets `environment:`, so both
  # forms must be listed.
  allowed_refs            = ["refs/heads/main", "refs/heads/develop"]
  allowed_gh_environments = ["staging"]

  # Alert at 95% only. ACTUAL-only: AWS rejects FORECASTED on DAILY.
  budget_usd        = 25
  budget_thresholds = [95]
  anomaly_usd       = 10
}

# --- Per-region SSM ------------------------------------------------------
#
# One alias and one block per region. SSM parameters are regional with no
# replication, and a resource's provider must be a STATIC reference — so
# this cannot be a loop over local.regions.

provider "aws" {
  alias   = "use1"
  region  = "us-east-1"
  profile = "meandr-staging"
}

resource "aws_ssm_parameter" "self_ips_euc1" {
  name  = local.self_ips_param
  type  = "StringList"
  value = join(",", module.global_accelerator.static_ips)
  tags  = local.account_tags
}

resource "aws_ssm_parameter" "self_ips_use1" {
  provider = aws.use1

  name  = local.self_ips_param
  type  = "StringList"
  value = join(",", module.global_accelerator.static_ips)
  tags  = local.account_tags
}

# --- Read-only observer for the AWS MCP server --------------------------
#
# STAGING ONLY, and deliberately so. ReadOnlyAccess is broad — it can read
# DynamoDB items and S3 objects, which in this account includes captured
# payloads. That is an accepted trade for being able to inspect the whole
# system; it would NOT be for production, which needs its own user with a
# policy narrowed to describe-and-metrics.
#
# The AWS MCP server signs with SigV4, so it needs a long-lived access key
# — it cannot assume a role or use SSO. That makes this the ONLY static
# credential in the estate.
#
# The ACCESS KEY IS NOT MANAGED HERE. aws_iam_access_key writes the secret
# into Terraform state in plaintext, and state outlives the key. Mint it by
# hand and put it straight in the cred-store:
#
#   aws iam create-access-key --user-name meandr-mcp-observer --profile meandr-staging
#
# Rotation is manual for the same reason. Access Analyzer and most SOC 2
# checklists flag static keys by age, so this is on the list to revisit —
# ideally by teaching the signer to assume a role instead.
resource "aws_iam_user" "mcp_observer" {
  name = "meandr-mcp-observer"
  path = "/mcp/"

  tags = merge(local.account_tags, {
    "meandr:purpose" = "aws-mcp-server read-only observer"
  })
}

resource "aws_iam_user_policy_attachment" "mcp_observer_readonly" {
  user       = aws_iam_user.mcp_observer.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

output "mcp_observer_user_name" {
  description = "Mint this user's access key by hand — see the comment above; a Terraform-managed key would sit in state."
  value       = aws_iam_user.mcp_observer.name
}
