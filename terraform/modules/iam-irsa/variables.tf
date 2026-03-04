variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider for IRSA"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS OIDC provider (without https://)"
  type        = string
}

variable "litellm_namespace" {
  description = "Kubernetes namespace for LiteLLM"
  type        = string
}

variable "litellm_service_account" {
  description = "Kubernetes service account name for LiteLLM"
  type        = string
}

variable "alb_controller_namespace" {
  type    = string
  default = "kube-system"
}

variable "alb_controller_service_account" {
  type    = string
  default = "aws-load-balancer-controller"
}

variable "secrets_arns" {
  description = "List of Secrets Manager ARNs that LiteLLM pods can read"
  type        = list(string)
  default     = []
}
