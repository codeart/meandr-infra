# development / eu-central-1 — region-level dev workload (cred-store).
#
# Mirror of staging/eu-central-1 in shape, much thinner in scope. The
# dev account today doesn't run any ECS / VPC workload — engineers
# point BE + proxy at localhost Redis from their laptops — so this
# caller only provisions the bits that have to live in AWS:
#
#   - meandr-creds-development DynamoDB table (cred blob storage)
#   - alias/meandr-cred-development KMS CMK (envelope encryption)
#   - IAM policy attached to the existing `meandr-dev` user that
#     grants R/W on the new resources (matches the union of BE-side
#     and proxy-side scopes since one human runs both locally)
#
# The dev IAM user itself + its base SM policy on `meandr/tenants/*`
# stays in account-development/, since identity is account-global.

provider "aws" {
  region  = local.region
  profile = "meandr-development"
}

locals {
  # This stack's identity. Everything below derives from these — the
  # provider, resource names, ARNs — so onboarding a region is a copy of
  # this file with the three edited.
  env        = "development"
  region     = "eu-central-1"
  account_id = "238020582774"

  # Is this the env's PRIMARY region? The archive is written by BE from
  # Postgres, which is central, so there is ONE archive per env and it
  # lives here. Secondary regions are mcp-only: they get a payloads
  # bucket — which IS per region, because the proxy writes it on the hot
  # path — and no archive.
  #
  # Deliberately NOT derived from whether the api module is present.
  # Production creates the archive bucket ahead of its deferred workload
  # to reserve the global S3 name, and development has no ECS at all yet
  # still writes an archive from a laptop.
  #
  # S3 catches half a mistake: `meandr-mcp-archive-<env>` is globally
  # unique, so a second region trying to create it fails loudly. The Glue
  # database would NOT — catalogs are per region, so a duplicate would
  # silently stand up an empty database whose queries return nothing.
  primary = true

  tags = {
    "meandr:env"        = local.env
    "meandr:managed-by" = "terraform"
    "meandr:owner"      = "infra"
  }

  # Dev-only. Staging and production scope the same ARNs inside
  # modules/meandr-api from var.env; here the IAM policies are written
  # out in this file, so the name is needed in five places.
  #
  # Named for the Rails env, not the 3-letter MEANDR_ENV — the app
  # derives it as `meandr_#{Rails.env}`.
  athena_database = "meandr_${local.env}"
}

# --- Account guard ------------------------------------------------------

data "aws_caller_identity" "current" {}

resource "null_resource" "account_guard" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == local.account_id
      error_message = "Account mismatch: expected ${local.account_id}, got ${data.aws_caller_identity.current.account_id}. Wrong AWS_PROFILE?"
    }
  }
}

# --- Cred store --------------------------------------------------------
#
# Single region, no replication, no PITR, no deletion protection — dev
# data is fully throwaway.

module "creds_table" {
  source = "../../modules/dynamodb-creds-table"

  name = "meandr-creds-${local.env}"

  pitr_enabled                = false
  deletion_protection_enabled = false

  tags = local.tags
}

module "cred_encryption_key" {
  source = "../../modules/cred-encryption-key"

  env        = local.env
  alias_name = "meandr-cred-${local.env}"

  enable_key_rotation     = true
  deletion_window_in_days = 7

  tags = local.tags
}

module "payload_encryption_key" {
  source = "../../modules/payload-encryption-key"

  env        = local.env
  alias_name = "meandr-payload-${local.env}"

  enable_key_rotation     = true
  deletion_window_in_days = 7

  # Dev is single-region (eu-central-1). Matches staging shape;
  # production is multi_region=true for future rollout.
  multi_region = false

  tags = local.tags
}

# --- Cred-store IAM policy on the dev user -----------------------------
#
# The user itself is created in account-development/. We look it up by
# name (stable) and attach a region-resource-scoped policy here. This
# is the dev equivalent of the per-app task-role policies in staging /
# production — one human running both BE and proxy locally needs the
# union of both scopes (R/W on the table, GenerateDataKey + Decrypt on
# the CMK, CRUD on the dated SM key path).

data "aws_iam_user" "dev" {
  user_name = "meandr-dev"
}

resource "aws_iam_policy" "dev_cred_store" {
  name        = "meandr-dev-cred-store"
  path        = "/dev/"
  description = "DynamoDB cred table + KMS envelope keys for local BE/proxy"
  tags        = local.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoCredTableReadWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable",
          "dynamodb:ListTables",
        ]
        Resource = module.creds_table.table_arn
      },
      {
        Sid    = "KMSCredEncryption"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = module.cred_encryption_key.key_arn
      },
      {
        # Payload CMK — approval-flow tool-call payload envelope
        # encryption. Dev user needs the union of proxy + BE
        # permissions (proxy: GenerateDataKey + Decrypt to encrypt on
        # emit and decrypt on replay; BE: Decrypt to unwrap on
        # dashboard "View Request/Response" clicks). No Encrypt — the
        # 4KB direct-KMS limit is a footgun and envelope encryption
        # via GenerateDataKey is the only sanctioned path.
        Sid    = "KMSPayloadEnvelope"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = module.payload_encryption_key.key_arn
      },
    ]
  })
}

resource "aws_iam_user_policy_attachment" "dev_cred_store" {
  user       = data.aws_iam_user.dev.user_name
  policy_arn = aws_iam_policy.dev_cred_store.arn
}

# --- S3 capture access (dev user) ---------------------------------------
#
# Its own policy rather than more statements on cred-store-access: a
# different subsystem, a different lifecycle, and keeping them apart means
# a change here can never be the reason cred-store access disappears.
#
# Staging and production grant the same thing to the ECS TASK ROLE
# instead (modules/meandr-mcp, capture_enabled). Dev is the odd one
# because the proxy and BE run on a laptop against a stored access key.

resource "aws_iam_policy" "dev_s3_capture" {
  name        = "meandr-dev-s3-capture"
  path        = "/dev/"
  description = "Payloads + archive bucket access for local BE/proxy capture"
  tags        = local.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Payloads bucket — the proxy's capture path. PutObject covers
        # CreateMultipartUpload / UploadPart / Complete; Abort is its own
        # action and is what the incomplete-upload lifecycle rule cannot
        # substitute for. PutObjectTagging is there for the retention tag
        # (set on CreateMultipartUpload, but a re-tag needs its own
        # permission). GetObject is the approval REPLAY read — an offline
        # approval is decided later, possibly elsewhere, so the body comes
        # back from here (policies.md §9.2.1). ListBucket is what the
        # monthly untagged-object sweep enumerates with.
        Sid    = "S3PayloadsReadWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectTagging",
          "s3:GetObject",
          "s3:GetObjectTagging",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListBucketMultipartUploads",
          "s3:ListMultipartUploadParts",
          "s3:ListBucket",
        ]
        Resource = [
          module.payloads_bucket.arn,
          "${module.payloads_bucket.arn}/*",
        ]
      },
      {
        # Archive bucket — BE writes Parquet, Athena reads it. ListBucket
        # is not optional for Athena: it enumerates partitions before it
        # scans.
        Sid    = "S3ArchiveReadWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectTagging",
          "s3:GetObject",
          "s3:GetObjectTagging",
          "s3:DeleteObject",
          "s3:ListBucket",
          # Athena calls GetBucketLocation on the results location BEFORE
          # it runs anything, and answers a missing grant with "Unable to
          # verify/create output bucket" — which reads as the bucket not
          # existing rather than as a permission. Results are written
          # here (athena-results/), and a large result set goes up as a
          # multipart upload, hence the three multipart actions.
          "s3:GetBucketLocation",
          "s3:AbortMultipartUpload",
          "s3:ListBucketMultipartUploads",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          one(module.archive_bucket[*].arn),
          "${one(module.archive_bucket[*].arn)}/*",
        ]
      },
    ]
  })
}

resource "aws_iam_user_policy_attachment" "dev_s3_capture" {
  user       = data.aws_iam_user.dev.user_name
  policy_arn = aws_iam_policy.dev_s3_capture.arn
}

# --- Athena (archive query API) -----------------------------------------
#
# The archive query API runs Athena over the Parquet in archive_bucket
# (Meandr::Athena, lib/meandr/athena.rb). In development the Rails client
# authenticates as THIS user, not the operator's own admin identity —
# same dev-vs-deployed split as Proxy::Payloads and Meandr::CredStore —
# so the grant has to live here or every query returns AccessDenied.
#
# S3 and KMS are already covered above: the archive bucket is R/W with
# ListBucket (Athena enumerates partitions before it scans), results land
# under the same bucket's athena-results/ prefix, and the bucket is
# SSE-KMS under payload_encryption_key, which the cred-store policy
# already grants GenerateDataKey + Decrypt on. Only the query engine and
# the catalog were missing.
#
# MANAGED, like every other grant on this user, and that is not a style
# choice. A user's INLINE policies share a 2048-byte budget IN AGGREGATE
# — across every stack that writes to that user, since IAM is global —
# and adding this one inline failed with LimitExceeded. Managed policies
# get 6144 bytes each and share nothing, which also decouples the two
# stacks that grant to meandr-dev from each other.
#
# The grant lives HERE, beside the resources it names, rather than in
# account-development with the user: these ARNs are regional, and a
# second dev region would attach its own policy to the same global user
# with no conflict. account-development keeps only the grants whose ARNs
# are region-agnostic.
resource "aws_iam_policy" "dev_athena" {
  name        = "meandr-dev-athena-query"
  path        = "/dev/"
  description = "Athena + Glue catalog read for the local BE's archive query API"
  tags        = local.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Scoped to the DEFAULT workgroup because the client does not
        # name one (athena.rb builds no work_group param). A dedicated
        # workgroup is the right home for per-query byte caps if archive
        # spend ever needs bounding; this follows the code as written.
        Sid    = "AthenaQueryExecution"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:StopQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:GetQueryResultsStream",
          "athena:ListQueryExecutions",
          "athena:GetWorkGroup",
        ]
        Resource = "arn:aws:athena:${local.region}:${local.account_id}:workgroup/primary"
      },
      {
        # READ-ONLY on the catalog: the query path only resolves tables
        # and partitions. DDL lives in its own policy below, so a grant
        # that exists for `rake archive:provision` can be removed without
        # touching the one queries depend on.
        Sid    = "GlueCatalogRead"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions",
        ]
        Resource = [
          "arn:aws:glue:${local.region}:${local.account_id}:catalog",
          "arn:aws:glue:${local.region}:${local.account_id}:database/${local.athena_database}",
          "arn:aws:glue:${local.region}:${local.account_id}:table/${local.athena_database}/*",
        ]
      },
    ]
  })
}

resource "aws_iam_user_policy_attachment" "dev_athena" {
  user       = data.aws_iam_user.dev.user_name
  policy_arn = aws_iam_policy.dev_athena.arn
}

# --- Glue table DDL (rake archive:provision) ----------------------------
#
# TABLES ONLY. The database is a Terraform resource (below) because it is
# stable infrastructure; the tables are not, because their columns are
# DERIVED — the rake task reads them off the Rails models and the
# Archiver writes the Parquet from those same models, so writer and
# reader schema cannot drift. Hand-maintaining the column list here would
# create exactly that drift, and silently: a migration adds a column, the
# Parquet carries it, and Athena cannot see it.
#
# So infra owns what it can state, and the app owns what only it knows.
#
# Separate from the query policy so a deployed environment can hold the
# read grant alone — no task role should be able to drop a catalog table.
# Provisioning is an operator action, run with an operator identity.
#
# No partition APIs: the tables use partition projection (see the rake
# task, "no Glue catalog, no MSCK"), so partitions are computed at query
# time and never registered.
resource "aws_iam_policy" "dev_glue_provision" {
  name        = "meandr-dev-glue-provision"
  path        = "/dev/"
  description = "Glue DDL for rake archive:provision (database + external tables)"
  tags        = local.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GlueTableDDL"
        Effect = "Allow"
        Action = [
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:DeleteTable",
        ]
        Resource = [
          "arn:aws:glue:${local.region}:${local.account_id}:catalog",
          "arn:aws:glue:${local.region}:${local.account_id}:database/${local.athena_database}",
          "arn:aws:glue:${local.region}:${local.account_id}:table/${local.athena_database}/*",
        ]
      },
    ]
  })
}

resource "aws_iam_user_policy_attachment" "dev_glue_provision" {
  user       = data.aws_iam_user.dev.user_name
  policy_arn = aws_iam_policy.dev_glue_provision.arn
}

# --- Capture buckets ----------------------------------------------------
#
# Two buckets, split by WHO WRITES and HOW IT IS READ
# (capture_and_archive.md §6):
#
#   archive   tool calls + actions as Parquet. Written by BE from
#             Postgres, which is central, so ONE bucket per env and
#             Athena stays single-region. Later: MCP logs.
#
#   payloads  request/response bodies. Written by the proxy on the hot
#             path, so it must be regional — but nothing ever SCANS it,
#             because a ref names the bucket and a byte range. That is
#             what keeps the archive queryable from one place.

module "archive_bucket" {
  source = "../../modules/s3-capture-bucket"
  count  = local.primary ? 1 : 0

  name        = "meandr-mcp-archive-${local.env}"
  kms_key_arn = module.payload_encryption_key.key_arn
  tags        = local.tags

  # Athena drops query results here and never cleans up.
  prefix_expirations = { "athena-results/" = 1 }
}

module "archive_database" {
  source = "../../modules/glue-database"
  count  = local.primary ? 1 : 0

  name        = local.athena_database
  description = "meandr archive (${local.env}) — external tables over ${one(module.archive_bucket[*].bucket)}"
  tags        = local.tags
}

module "payloads_bucket" {
  source = "../../modules/s3-capture-bucket"

  name        = "meandr-mcp-payloads-${local.region}-${local.env}"
  kms_key_arn = module.payload_encryption_key.key_arn
  tags        = local.tags
}

# --- Outputs ------------------------------------------------------------

output "archive_bucket" {
  description = "Dev archive bucket (calls + actions Parquet). Athena reads this one; it is the only bucket that gets scanned."
  value       = one(module.archive_bucket[*].bucket)
}

output "payloads_bucket" {
  description = "Dev payloads bucket (request/response bodies). Set as MEANDR_CAPTURE_BUCKET in local .env — the locally-running proxy writes here."
  value       = module.payloads_bucket.bucket
}

output "creds_table_name" {
  description = "Dev cred-store Dynamo table name. Set as MEANDR_CRED_TABLE_NAME in local .env."
  value       = module.creds_table.table_name
}

output "creds_table_arn" {
  description = "Dev cred-store Dynamo table ARN."
  value       = module.creds_table.table_arn
}

output "cred_encryption_key_alias" {
  description = "Dev cred-store KMS alias (full form, including `alias/`). Set as MEANDR_CRED_KMS_KEY_ALIAS in local .env."
  value       = module.cred_encryption_key.alias_name
}

output "cred_encryption_key_arn" {
  description = "Dev cred-store KMS CMK ARN."
  value       = module.cred_encryption_key.key_arn
}

output "payload_encryption_key_alias" {
  description = "Dev payload KMS alias (full form, including `alias/`). Set as MEANDR_PAYLOAD_KMS_KEY_ALIAS in local .env when you want the approval flow to exercise real KMS locally. Unset it to use the NoopCipher (plaintext through the wire, dev-only)."
  value       = module.payload_encryption_key.alias_name
}

output "payload_encryption_key_arn" {
  description = "Dev payload KMS CMK ARN — approval-flow envelope encryption."
  value       = module.payload_encryption_key.key_arn
}
