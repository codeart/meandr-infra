# Outputs are mostly for documentation — humans copy these into the
# backend "s3" blocks of other Terraform modules. Not consumed by
# terraform_remote_state (bootstrap's state is local, so other modules
# can't read its outputs anyway).

output "state_bucket_name" {
  description = "S3 bucket holding Terraform state for every other module"
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket — needed for IAM policies on deploy roles"
  value       = aws_s3_bucket.tfstate.arn
}

output "lock_table_name" {
  description = "DynamoDB table for state locks"
  value       = aws_dynamodb_table.tfstate_locks.id
}

output "lock_table_arn" {
  description = "ARN of the lock table — needed for IAM policies on deploy roles"
  value       = aws_dynamodb_table.tfstate_locks.arn
}

output "kms_key_arn" {
  description = "KMS key ARN — referenced by other modules' backend blocks for state encryption"
  value       = aws_kms_key.tfstate.arn
}

output "log_bucket_name" {
  description = "S3 bucket holding access logs for the state bucket"
  value       = aws_s3_bucket.logs.id
}

output "region" {
  description = "Region these resources live in"
  value       = var.region
}

# Convenience: prints the exact backend block to paste into other modules.
output "backend_config_example" {
  description = "Copy-paste this into other modules' terraform { backend \"s3\" { ... } } block, substituting the correct key path."
  value = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.tfstate.id}"
        key            = "<env>/<region>/terraform.tfstate"   # e.g. "staging/eu-central-1/terraform.tfstate"
        region         = "${var.region}"
        dynamodb_table = "${aws_dynamodb_table.tfstate_locks.id}"
        kms_key_id     = "${aws_kms_key.tfstate.arn}"
        encrypt        = true
      }
    }
  EOT
}
