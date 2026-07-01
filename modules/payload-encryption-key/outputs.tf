output "key_arn" {
  description = "CMK ARN. Used by consumer modules to scope IAM policies (proxy GenerateDataKey + Decrypt, BE Decrypt-on-user-view). Also goes into the proxy's MEANDR_PAYLOAD_KMS_KEY_ALIAS env var as the alias form for stability across rotations."
  value       = aws_kms_key.main.arn
}

output "key_id" {
  description = "CMK key ID (the UUID-like identifier). ARN form is preferred for IAM; this is here for diagnostic / console-link use."
  value       = aws_kms_key.main.key_id
}

output "alias_name" {
  description = "Full alias name including the `alias/` prefix. This is the stable handle callers use for KMS calls — survives CMK rotation if we ever swap the underlying key."
  value       = aws_kms_alias.main.name
}

output "alias_arn" {
  description = "Alias ARN. Some IAM action contexts accept alias ARNs in place of key ARNs."
  value       = aws_kms_alias.main.arn
}
