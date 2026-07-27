output "cloudfront_url" {
  description = "LiteLLM 网关访问地址（唯一对外入口）"
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.main.domain_name
}

output "master_key_secret_arn" {
  description = "master key 存放的 Secrets Manager ARN（用 aws secretsmanager get-secret-value 取）"
  value       = aws_secretsmanager_secret.master_key.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.litellm.repository_url
}

output "alb_dns_name" {
  description = "ALB 内部 DNS（不对外，仅 CloudFront origin）"
  value       = aws_lb.main.dns_name
}

output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service" {
  value = aws_ecs_service.litellm.name
}

# 便捷：取 master key 明文的命令
output "get_master_key_cmd" {
  value = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.master_key.arn} --query SecretString --output text --region ${var.aws_region}"
}
