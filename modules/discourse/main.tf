# A Discourse forum on its own island: one VPC, one zone, one of each
# tier, nothing shared with the meandr data plane. Everything sits in the
# private subnet and reaches the world through our own NAT instance, which
# also forwards 80/443 back in — no ALB, no public address on the app.
#
# Every tier is a shared module used unmodified; this file only composes
# them and owns the app instance itself. See docs/infra/discourse.md.

data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_caller_identity" "current" {}

locals {
  name = "discourse-${var.env}"

  # Hostname without the zone, for the record name.
  record_name = trimsuffix(var.hostname, ".${var.public_zone_name}")

  # RDS's subnet group demands two subnets even for a single-AZ instance,
  # so the VPC carries a second zone that holds NOTHING. Every running
  # thing is placed in var.az, index 0.
  azs       = [var.az, local.second_az]
  second_az = var.az == "${var.region}a" ? "${var.region}b" : "${var.region}a"

  # Derived from vars, never from the zone resource: the NAT embeds this in
  # user-data, and a value that is only known after apply would make
  # user_data_replace_on_change undecidable at plan time.
  internal_zone = "discourse.${var.env}.meandr.internal"

  # What the NAT forwards to. The app owns this record and moves it when it
  # is replaced; only the NAT's resolver reads it.
  app_record = "app.${local.internal_zone}"
}

# --- Network --------------------------------------------------------------

module "vpc" {
  source = "../vpc"

  # `env` only qualifies Name tags in this module — which is the point:
  # the environment's real VPC is already "Main VPC - production".
  env               = local.name
  cidr_block        = var.vpc_cidr
  azs               = local.azs
  internal_dns_zone = local.internal_zone

  # NAT is attached below by name, not here: the vpc module's NAT takes
  # the account-global name `nat-<az>`, which the main stack already owns.
  enable_nat = false

  tags = var.tags
}

module "nat" {
  source = "../nat-instance"

  env           = var.env
  name          = "${local.name}-nat"
  az            = var.az
  vpc_id        = module.vpc.vpc_id
  subnet_id     = module.vpc.public_subnet_ids[0]
  vpc_cidr      = var.vpc_cidr
  instance_type = var.nat_instance_type

  # The forum's only public face. Real client addresses reach the app —
  # the module skips masquerade on forwarded flows — so Discourse's own
  # rate limiting and IP bans see visitors, not one NAT.
  #
  # By NAME, not address: the app is replaced on every upgrade, and a
  # pinned address would force destroy-before-create. The NAT re-resolves
  # this record every 30s, so a new instance takes over when the record
  # moves — no NAT replacement, no downtime.
  forwards = [
    { port = 80, target_host = local.app_record, description = "HTTP: ACME challenge + redirect" },
    { port = 443, target_host = local.app_record, description = "HTTPS: the forum" },
  ]

  alarm_topic_arns = var.alarm_topic_arns
  tags             = var.tags
}

# The private subnets' way out. The vpc module owns the table; with
# enable_nat = false it left the default route for us to point.
resource "aws_route" "private_default" {
  route_table_id         = module.vpc.private_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.nat.network_interface_id
}

# --- Data -----------------------------------------------------------------

module "db" {
  source = "../rds-postgres"

  name               = local.name
  db_name            = "discourse"
  master_username    = "discourse"
  engine_version     = var.db_engine_version
  instance_class     = var.db_instance_class
  vpc_id             = module.vpc.vpc_id
  vpc_cidr_block     = var.vpc_cidr
  private_subnet_ids = module.vpc.private_subnet_ids
  secret_name        = "meandr/discourse/${var.env}/db"

  # A 1 GiB instance. Same tuning staging runs its db.t4g.micro with.
  db_parameters = {
    autovacuum_max_workers = "1"
    autovacuum_work_mem    = "32768"
    max_connections        = "50"
  }

  tags = var.tags
}

resource "random_password" "valkey_auth" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "valkey_auth" {
  name = "meandr/discourse/${var.env}/valkey-auth"
  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "valkey_auth" {
  secret_id     = aws_secretsmanager_secret.valkey_auth.id
  secret_string = random_password.valkey_auth.result
}

# valkey-node binds no reservation of its own — a fleet node matches
# valkey-region's open one, which this stack does not have. Targeted, so
# the main stack's fleet cannot consume it.
resource "aws_ec2_capacity_reservation" "valkey" {
  instance_type           = var.valkey_instance_type
  instance_platform       = "Linux/UNIX"
  availability_zone       = var.az
  instance_count          = 1
  end_date_type           = "unlimited"
  instance_match_criteria = "targeted"

  tags = merge(var.tags, { Name = "${local.name}-valkey" })
}

# Standalone and plaintext: one client, one subnet, guarded by AUTH and the
# security group. noeviction because Discourse keeps Sidekiq's queue here,
# not just a cache — an evicted job is a lost job.
module "valkey" {
  source = "../valkey-node"

  fleet                   = "discourse"
  node                    = "a"
  name                    = "discourse-valkey-a" # sorts with the rest of this stack in the console
  role                    = "master"
  standalone              = true
  tls_enabled             = false
  run_sentinel            = false
  instance_type           = var.valkey_instance_type
  capacity_reservation_id = aws_ec2_capacity_reservation.valkey.id

  valkey_version       = var.valkey_version
  valkey_source_bucket = var.valkey_source_bucket
  valkey_source_sha256 = filesha256(var.valkey_source_path)
  auth_secret_arn      = aws_secretsmanager_secret.valkey_auth.arn

  maxmemory_policy = "noeviction"

  vpc_id        = module.vpc.vpc_id
  subnet_id     = module.vpc.private_subnet_ids[0]
  client_cidrs  = [var.vpc_cidr]
  dns_zone_id   = module.vpc.internal_dns_zone_id
  dns_zone_name = module.vpc.internal_dns_zone_name

  tags = var.tags

  depends_on = [aws_route.private_default]
}

# The name the app connects by. valkey-fleet owns this record for a real
# fleet because failover moves it; a lone node never fails over, so it
# is ours and it never moves.
resource "aws_route53_record" "valkey_master" {
  zone_id = module.vpc.internal_dns_zone_id
  name    = "discourse-master.valkey.${module.vpc.internal_dns_zone_name}"
  type    = "CNAME"
  ttl     = 60
  records = [module.valkey.hostname]
}

# --- Object storage -------------------------------------------------------
#
# Everything of value lives OFF the box — RDS, Valkey, and these two
# buckets — which is what makes the instance disposable and a replacement
# safe. Two buckets, deliberately: uploads are served straight to browsers
# and must be public-read; a backup is a full database dump and must never
# sit in a public-read bucket, whatever the prefix.

# Uploads. PUBLIC-READ, the one bucket in this account that is: Discourse
# hands browsers direct S3 URLs for every image. Not s3-capture-bucket,
# which enforces the block this bucket must not have.
resource "aws_s3_bucket" "uploads" {
  bucket = "meandr-discourse-uploads-${var.env}"
  tags   = merge(var.tags, { Name = "meandr-discourse-uploads-${var.env}" })
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  # Object ACLs stay blocked — reads are granted by ONE bucket policy below,
  # not by per-object ACLs Discourse would have to set on every upload.
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_ownership_controls" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_policy" "uploads_public_read" {
  bucket = aws_s3_bucket.uploads.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadUploads"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.uploads.arn}/*"
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.uploads]
}

resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  # Direct-to-S3 uploads from the browser need the forum's origin allowed.
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD", "PUT", "POST"]
    allowed_origins = ["https://${var.hostname}"]
    max_age_seconds = 3000
  }
}

# Backups. Private. Discourse's scheduled backups land here instead of on
# the root volume, where a dead box would take them with it.
resource "aws_s3_bucket" "backups" {
  bucket = "meandr-discourse-backups-${var.env}"
  tags   = merge(var.tags, { Name = "meandr-discourse-backups-${var.env}" })
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# Discourse keeps its own N-most-recent on the app side; this is the
# backstop so a misconfigured schedule cannot grow the bucket forever.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter {}
    expiration { days = 30 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

# --- Secrets the app reads at boot ----------------------------------------

# Terraform owns the CONTAINER; the operator puts the Postmark token in by
# hand. NO secret_version here — the value must never enter state.
resource "aws_secretsmanager_secret" "smtp" {
  name        = "meandr/discourse/${var.env}/smtp-password"
  description = "Postmark server API token, used as both SMTP username and password."
  tags        = var.tags
}

# --- App instance ---------------------------------------------------------

resource "aws_security_group" "app" {
  name        = local.name
  description = "Discourse app"
  vpc_id      = module.vpc.vpc_id
  tags        = merge(var.tags, { Name = local.name })
}

# Only what the NAT forwards, and only from inside the VPC: the forwarded
# packet arrives with the CLIENT's source address, but it arrives on the
# NAT's interface, so the SG sees traffic from anywhere. Narrowing the
# source here to the VPC would drop it. The NAT's own SG is the boundary.
resource "aws_vpc_security_group_ingress_rule" "app_http" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "Forwarded by the NAT"
}

resource "aws_vpc_security_group_ingress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Forwarded by the NAT"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# SSM Session Manager is the only way onto this box. No SSH key, no port
# 22, and the audit trail comes free.
resource "aws_iam_role" "app" {
  name = local.name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = local.name })
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Exact ARNs, never a wildcard: the three secrets this box may read.
resource "aws_iam_role_policy" "app_secrets" {
  name = "discourse-secrets"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "secretsmanager:GetSecretValue"
      Resource = [
        module.db.secret_arn,
        aws_secretsmanager_secret.valkey_auth.arn,
        aws_secretsmanager_secret.smtp.arn,
      ]
    }]
  })
}

# The instance role IS the S3 credential (DISCOURSE_S3_USE_IAM_PROFILE):
# no access keys anywhere, and the grant is exactly these two buckets.
resource "aws_iam_role_policy" "app_s3" {
  name = "discourse-s3"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.uploads.arn, aws_s3_bucket.backups.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject", "s3:GetObject", "s3:DeleteObject",
          "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts",
        ]
        Resource = ["${aws_s3_bucket.uploads.arn}/*", "${aws_s3_bucket.backups.arn}/*"]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = local.name
  role = aws_iam_role.app.name
}

# Held before it is needed: a forum that cannot relaunch after a rebuild
# is a forum that is down until capacity appears. Targeted, so nothing
# else consumes it.
#
# TWO slots, not one. create_before_destroy means the replacement launches
# while the old instance still holds its slot, and a full reservation
# refuses it — the deploy would fail at the worst moment. The second slot
# is idle except during a deploy; that is what it costs to never wait for
# capacity mid-cutover.
resource "aws_ec2_capacity_reservation" "app" {
  instance_type           = var.app_instance_type
  instance_platform       = "Linux/UNIX"
  availability_zone       = var.az
  instance_count          = var.app_capacity_slots
  end_date_type           = "unlimited"
  instance_match_criteria = "targeted"

  tags = merge(var.tags, { Name = local.name })
}

resource "aws_instance" "app" {
  ami                  = data.aws_ssm_parameter.al2023_arm.value
  instance_type        = var.app_instance_type
  iam_instance_profile = aws_iam_instance_profile.app.name

  capacity_reservation_specification {
    capacity_reservation_target {
      capacity_reservation_id = aws_ec2_capacity_reservation.app.id
    }
  }

  # No pinned address: two instances coexist during a cutover, and one IP
  # cannot be held by two ENIs. The NAT follows the record instead.
  subnet_id              = module.vpc.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]

  user_data_base64            = base64gzip(local.user_data)
  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.app_root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  tags = merge(var.tags, {
    Name = local.name
    Role = "discourse"
  })

  lifecycle {
    ignore_changes = [ami]

    # The replacement is built and proven serving BEFORE the old one goes:
    # everything that mattered has moved off this box (RDS, Valkey, S3), so
    # the only thing an upgrade costs is the moment the record moves.
    create_before_destroy = true
  }

  # Boot fetches secrets and pulls images through the NAT; nothing works
  # until the route exists.
  depends_on = [aws_route.private_default]
}

# --- Cutover --------------------------------------------------------------
#
# The order Terraform derives from these three: new instance → proven
# serving → record moves → (resolver picks it up) → drain → old instance
# destroyed. Each step depends on the one before it, so none of it is
# timing luck.

# Serving, not merely running: cloud-init takes ~7 minutes to build the
# image, and a record moved to a booting box is a dark forum. /srv/status
# is Discourse's own health endpoint and answers only once it is up.
resource "terraform_data" "app_ready" {
  triggers_replace = [aws_instance.app.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      AWS_PROFILE = var.aws_profile
      AWS_REGION  = var.region
    }
    command = <<-EOT
      set -euo pipefail
      target='${aws_instance.app.private_ip}'
      deadline=$((SECONDS + ${var.app_ready_timeout_seconds}))
      echo "discourse: waiting for $target to serve"
      while (( SECONDS < deadline )); do
        cmd=$(aws ssm send-command \
          --instance-ids '${module.nat.instance_id}' \
          --document-name AWS-RunShellScript \
          --parameters "commands=[\"curl -sf -m 5 -o /dev/null http://$target/srv/status\"]" \
          --query Command.CommandId --output text) || { sleep 10; continue; }
        sleep 8
        status=$(aws ssm get-command-invocation --command-id "$cmd" \
          --instance-id '${module.nat.instance_id}' --query Status --output text 2>/dev/null || echo Pending)
        [[ "$status" == Success ]] && { echo "discourse: $target is serving"; exit 0; }
        sleep 10
      done
      echo "discourse: $target never served within ${var.app_ready_timeout_seconds}s — record NOT moved" >&2
      exit 1
    EOT
  }
}

# Moving this record IS the cutover. The NAT re-resolves every 30s and
# swaps its DNAT chain in one transaction.
resource "aws_route53_record" "app" {
  zone_id = module.vpc.internal_dns_zone_id
  name    = local.app_record
  type    = "A"
  ttl     = 60
  records = [aws_instance.app.private_ip]

  # Moving it IS the cutover, so overwriting the existing value is the
  # operation, not a conflict to refuse.
  allow_overwrite = true

  depends_on = [terraform_data.app_ready]
}

# Hold the old instance alive while the NAT notices (≤30s) and in-flight
# requests finish. Destroying it the instant the record changed would black
# the site out for exactly that window.
resource "time_sleep" "drain" {
  triggers = { instance = aws_instance.app.id }

  create_duration = var.app_drain_duration

  depends_on = [aws_route53_record.app]
}

# --- Public name ----------------------------------------------------------

data "aws_route53_zone" "public" {
  provider     = aws.dns
  name         = var.public_zone_name
  private_zone = false
}

resource "aws_route53_record" "public" {
  provider = aws.dns
  zone_id  = data.aws_route53_zone.public.zone_id
  name     = local.record_name
  type     = "A"
  ttl      = 300
  records  = [module.nat.public_ip]
}

# --- Recipes: change the running box without a rebuild --------------------

module "recipes" {
  source = "../ssm-recipes"

  instance_ids = [aws_instance.app.id]
  recipes_dir  = "${path.module}/recipes"
  label        = local.name
  aws_profile  = var.aws_profile
  aws_region   = var.region

  # A recipe cannot start until cloud-init finishes, and first boot builds
  # the whole Discourse image — ~7 min, far past the 300s a Valkey node
  # needs. Measured 2026-09-16: 410s boot, runner gave up at 300.
  timeout_seconds = 900
}
