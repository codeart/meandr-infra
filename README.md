# meandr-infra

Terraform configuration for meandr's AWS infrastructure. Five AWS accounts under one Organization (see [`deployment_strategy.md`](docs/deployment_strategy.md) for the topology).

## Directory layout

```
bootstrap/        One-time setup; creates the Terraform state backend in Shared.
                  Uses LOCAL state (chicken-and-egg). Run once from a laptop.

modules/          Reusable Terraform modules consumed by per-env directories.
                  (Not yet built — Phase 2 work.)

shared/           Resources in the Shared account that aren't env-specific:
                  ECR, Route 53, OIDC providers, etc.
                  (Not yet built.)

dev/eu-central-1/         Dev sandbox; minimal — no proxy, no BE.
staging/eu-central-1/     Staging primary region.
staging/us-east-1/        Staging secondary region.
production/eu-central-1/  Production primary region.
production/us-east-1/     Production secondary region.
                          (None of these built yet.)

docs/             Symlink to ../meandr-docs (cross-repo shared docs).
```

## Bootstrap (run once)

The state backend doesn't exist yet — we have to create it with local state, then everything else uses it as a remote backend.

```bash
# 1. Sign into AWS via Identity Center (admin on Shared account)
aws sso login --profile meandr-shared

# 2. Apply the bootstrap module
cd bootstrap/
terraform init
terraform plan
terraform apply
```

This creates in the Shared account (303529433558):
- S3 bucket for Terraform state (versioned, encrypted, public-access-blocked)
- DynamoDB table for state locks
- KMS key for state encryption at rest
- S3 bucket for state access logging

After this, all other modules use the S3 backend. Bootstrap state stays local; don't commit `bootstrap/terraform.tfstate`.

## SSO profile setup

`~/.aws/config` should have entries like:

```ini
[sso-session meandr]
sso_start_url = https://meandr.awsapps.com/start/
sso_region = eu-central-1
sso_registration_scopes = sso:account:access

[profile meandr-shared]
sso_session = meandr
sso_account_id = 303529433558
sso_role_name = AdministratorAccess
region = eu-central-1

[profile meandr-staging]
sso_session = meandr
sso_account_id = 259534890849
sso_role_name = AdministratorAccess
region = eu-central-1

[profile meandr-production]
sso_session = meandr
sso_account_id = 393686273464
sso_role_name = AdministratorAccess
region = eu-central-1
```

After `aws sso login --profile <name>`, Terraform picks up credentials automatically.

## See also

- `docs/deployment_strategy.md` — overall topology, phasing, and decisions.
- `docs/redis_schema.md` — wire-format contract between meandr-mcp and meandr-api.
