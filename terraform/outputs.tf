output "vpc_id" {
  description = "VPC ID"
  value       = local.vpc_id
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = module.ecr.repository_url
}

output "litellm_master_key" {
  description = "LiteLLM Master Key (also stored in Secrets Manager)"
  value       = aws_secretsmanager_secret_version.litellm_master_key.secret_string
  sensitive   = true
}

output "master_key_secret_arn" {
  description = "AWS Secrets Manager ARN for LiteLLM Master Key"
  value       = aws_secretsmanager_secret.litellm_master_key.arn
}

output "kubeconfig_command" {
  description = "Command to update kubeconfig"
  value       = "aws eks update-kubeconfig --name ${local.cluster_name} --region ${var.aws_region}"
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = var.enable_waf ? module.waf[0].web_acl_arn : null
}

output "dns_setup" {
  description = "DNS CNAME record to create"
  value       = "Create CNAME: ${var.litellm_host} -> (ALB DNS from: kubectl get ingress -n litellm litellm-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = module.rds.db_endpoint
}

output "rds_identifier" {
  description = "RDS instance identifier"
  value       = module.rds.db_identifier
}

output "cloudfront_distribution_domain" {
  description = "CloudFront distribution domain name"
  value       = var.enable_cloudfront ? module.cloudfront[0].distribution_domain_name : null
}

output "cf_origin_secret" {
  description = "Shared secret for X-CF-Secret header (configure ALB to validate this)"
  value       = var.enable_cloudfront ? module.cloudfront[0].cf_origin_secret : null
  sensitive   = true
}

output "cloudfront_alb_security_group_id" {
  description = "Security group ID that restricts ALB to CloudFront-only ingress"
  value       = var.enable_cloudfront ? module.cloudfront[0].alb_security_group_id : null
}
