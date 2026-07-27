terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# 主 provider — Fargate/ALB/VPC 资源所在区（默认 us-east-1，Bedrock GPT+Claude 都在）
provider "aws" {
  region = var.aws_region
}

# CloudFront 用的 ACM 证书必须在 us-east-1；本栈默认就是 us-east-1，保留别名以防主区改动
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
