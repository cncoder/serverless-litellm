variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "alb_dns_name" {
  description = "ALB DNS name to use as CloudFront origin"
  type        = string
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN in us-east-1 for CloudFront"
  type        = string
  default     = ""
}

variable "cloudfront_domain" {
  description = "Alternate domain name (CNAME) for the CloudFront distribution"
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC ID for the ALB security group"
  type        = string
}
