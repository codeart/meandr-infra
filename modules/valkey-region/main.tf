# Every Valkey fleet in a region, plus the artifacts, reservations and
# backups they share. One call per region; `fleets` is what differs.

locals {
  azs = [for az in ["a", "b", "c"] : "${var.region}${az}"]
}

# Region-local by necessity: nodes fetch through the S3 GATEWAY ENDPOINT,
# which only reaches the regional service. A bucket elsewhere would put NAT
# egress back on the boot path that vendoring the source removes.
resource "aws_s3_bucket" "artifacts" {
  bucket = "meandr-artifacts-${var.env}-${var.region}"
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioned so overwriting a key cannot destroy the source a node would
# fetch if it were replaced today.
resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# source_hash re-uploads when the vendored file changes; without it
# Terraform compares only metadata and a re-vendored tarball would sit in
# the repo while the old bytes stayed in the bucket.
resource "aws_s3_object" "valkey_source" {
  bucket      = aws_s3_bucket.artifacts.id
  key         = "valkey/${var.valkey_version}/valkey-src.tar.gz"
  source      = var.valkey_source_path
  source_hash = filemd5(var.valkey_source_path)

  tags = var.tags
}

# One slot per fleet per AZ, sized from the fleet count so adding a fleet
# cannot leave a node without capacity.
#
# Apply this FIRST and alone — nothing binds an instance to a reservation,
# so the only thing that makes one count is existing before the launch:
#
#   terraform apply -target=module.valkey.aws_ec2_capacity_reservation.nodes
#
# Never with depends_on on the fleets: that defers their data sources,
# local.user_data goes unknown at plan time, and user_data_replace_on_change
# silently stops firing.
resource "aws_ec2_capacity_reservation" "nodes" {
  for_each = toset(local.azs)

  instance_type           = var.instance_type
  instance_platform       = "Linux/UNIX"
  availability_zone       = each.value
  instance_count          = length(var.fleets)
  end_date_type           = "unlimited"
  instance_match_criteria = "open"

  tags = merge(var.tags, { Name = "valkey-nodes-${each.value}" })
}

# Keys are timestamped and never overwritten, so there is nothing to
# version — only to expire.
resource "aws_s3_bucket" "backups" {
  bucket = var.backup_bucket
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration { days = var.backup_retention_days }
  }
}

module "fleet" {
  source   = "../valkey-fleet"
  for_each = var.fleets

  fleet       = each.key
  region_code = var.region_code

  promotable           = each.value.promotable
  create_master_record = each.value.create_master_record
  master_record_label  = each.value.master_record_label
  maxmemory_policy     = each.value.maxmemory_policy

  # The literal name, never aws_s3_bucket.backups.id: the node module gates
  # its backup IAM on a count, and a computed id is unknown at plan time.
  backup_bucket = each.value.backup_bucket_enabled ? var.backup_bucket : ""

  valkey_version       = var.valkey_version
  valkey_source_bucket = aws_s3_bucket.artifacts.id
  valkey_source_sha256 = filesha256(var.valkey_source_path)

  instance_type   = var.instance_type
  sentinel_quorum = var.sentinel_quorum

  auth_secret_arn = var.auth_secret_arn
  tls_secret_arn  = var.tls_secret_arn

  vpc_id        = var.vpc_id
  subnet_ids    = var.subnet_ids
  client_cidrs  = var.client_cidrs
  dns_zone_id   = var.dns_zone_id
  dns_zone_name = var.dns_zone_name

  tags = var.tags
}
