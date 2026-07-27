variable "aws_region" {
  description = "主区（Fargate/ALB/VPC）。Bedrock Claude + GPT-mantle 均在 us-east-1"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "资源命名前缀"
  type        = string
  default     = "litellm-fg"
}

variable "environment" {
  type    = string
  default = "demo"
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "image_tag" {
  description = "ECR 中 litellm 镜像 tag"
  type        = string
  default     = "latest"
}

variable "task_cpu" {
  description = "Fargate task vCPU（1024 = 1 vCPU）"
  type        = number
  default     = 1024
}

variable "task_memory" {
  description = "Fargate task 内存 MiB"
  type        = number
  default     = 2048
}

variable "desired_count" {
  description = "Fargate service 副本数（最小栈=1）"
  type        = number
  default     = 1
}

variable "bedrock_region" {
  description = "Bedrock 推理区（Claude + GPT mantle）"
  type        = string
  default     = "us-east-1"
}
