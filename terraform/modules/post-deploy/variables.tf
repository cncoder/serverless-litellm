variable "cluster_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "litellm_master_key" {
  type      = string
  sensitive = true
}

variable "ecr_repository_url" {
  description = "ECR repository URL for LiteLLM custom image"
  type        = string
}

variable "dynamodb_table_name" {
  description = "DynamoDB API keys table name"
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

variable "database_url" {
  description = "PostgreSQL DATABASE_URL for LiteLLM Admin UI"
  type        = string
  sensitive   = true
}
