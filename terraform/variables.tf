variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "litellm"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

# VPC
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.3.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
  default     = ["us-west-2a", "us-west-2b"]
}

variable "create_vpc" {
  description = "是否创建新 VPC（false 则使用已有 VPC）"
  type        = bool
  default     = true
}

variable "existing_vpc_id" {
  description = "已有 VPC ID（create_vpc=false 时使用）"
  type        = string
  default     = ""
}

variable "existing_public_subnet_ids" {
  description = "已有 public 子网 ID 列表（create_vpc=false 时使用）"
  type        = list(string)
  default     = []
}

variable "existing_private_subnet_ids" {
  description = "已有 private 子网 ID 列表（create_vpc=false 时使用）"
  type        = list(string)
  default     = []
}

# EKS
variable "eks_version" {
  description = "EKS cluster version"
  type        = string
  default     = "1.31"
}

# ALB / Security
variable "acm_certificate_arn" {
  description = "ACM certificate ARN for *.example.com"
  type        = string
  default     = ""
}

variable "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN"
  type        = string
  default     = ""
}

variable "cognito_user_pool_client_id" {
  description = "Cognito User Pool Client ID"
  type        = string
  default     = ""
}

variable "cognito_user_pool_domain" {
  description = "Cognito User Pool Domain"
  type        = string
  default     = ""
}

variable "enable_cognito" {
  description = "是否启用 Cognito UI 认证"
  type        = bool
  default     = false
}

variable "litellm_host" {
  description = "LiteLLM hostname"
  type        = string
  default     = "litellm.example.com"
}

variable "bot_host" {
  description = "Bot/webhook hostname"
  type        = string
  default     = "bot.example.com"
}

# Kubernetes
variable "litellm_namespace" {
  description = "Kubernetes namespace for LiteLLM"
  type        = string
  default     = "litellm"
}

variable "litellm_service_account" {
  description = "Kubernetes service account for LiteLLM"
  type        = string
  default     = "litellm-sa"
}

# WAF
variable "enable_waf" {
  description = "是否启用 WAF 防护"
  type        = bool
  default     = false
}
