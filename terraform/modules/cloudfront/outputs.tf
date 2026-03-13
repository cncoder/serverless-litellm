output "distribution_domain_name" {
  description = "CloudFront distribution domain name"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "distribution_id" {
  description = "CloudFront distribution ID"
  value       = aws_cloudfront_distribution.main.id
}

output "cf_origin_secret" {
  description = "Shared secret for X-CF-Secret header between CloudFront and ALB"
  value       = random_password.cf_origin_secret.result
  sensitive   = true
}

output "alb_security_group_id" {
  description = "Security group ID that restricts ALB ingress to CloudFront only"
  value       = aws_security_group.alb_cloudfront_only.id
}
