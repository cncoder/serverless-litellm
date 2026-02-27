variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "litellm_host" {
  description = "LiteLLM hostname (e.g., litellm.example.com)"
  type        = string
}

variable "bot_host" {
  description = "Bot/webhook hostname (e.g., bot.example.com)"
  type        = string
  default     = ""
}
