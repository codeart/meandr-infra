output "certificate_arn" {
  description = "ARN of the validated certificate. Use this on ALB listeners, CloudFront, etc."
  value       = aws_acm_certificate_validation.main.certificate_arn
}

output "domain_name" {
  description = "Primary domain on the cert."
  value       = aws_acm_certificate.main.domain_name
}

output "subject_alternative_names" {
  description = "All SANs (excluding primary). Useful for verifying coverage."
  value       = aws_acm_certificate.main.subject_alternative_names
}
