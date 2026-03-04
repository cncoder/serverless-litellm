variable "cluster_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "master_key_secret_id" {
  description = "Secrets Manager secret ID for LiteLLM Master Key"
  type        = string
}

variable "db_password_secret_id" {
  description = "Secrets Manager secret ID for RDS DB password"
  type        = string
}

variable "database_url_base" {
  description = "PostgreSQL connection URL with __DB_PASSWORD__ placeholder"
  type        = string
}

variable "ecr_repository_url" {
  description = "ECR repository URL for LiteLLM custom image"
  type        = string
}

variable "acm_certificate_arn" {
  type = string
}

variable "enable_cognito" {
  description = "Whether to enable Cognito UI authentication"
  type        = bool
  default     = false
}

variable "cognito_user_pool_arn" {
  type    = string
  default = ""
}

variable "cognito_user_pool_client_id" {
  type    = string
  default = ""
}

variable "cognito_user_pool_domain" {
  type    = string
  default = ""
}

variable "litellm_host" {
  type = string
}

variable "bot_host" {
  type    = string
  default = "bot.example.com"
}

variable "eks_cluster_endpoint" {
  type = string
}

variable "litellm_pod_role_arn" {
  description = "IAM role ARN for LiteLLM pods (IRSA)"
  type        = string
}

