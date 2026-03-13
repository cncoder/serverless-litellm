# CloudFront Origin Secret - shared between CF custom header and ALB validation
resource "random_password" "cf_origin_secret" {
  length  = 64
  special = false
}

# Managed prefix list for CloudFront origin-facing IPs
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# Security Group: restrict ALB ingress to CloudFront only
resource "aws_security_group" "alb_cloudfront_only" {
  name_prefix = "${var.project_name}-alb-cf-${var.environment}-"
  description = "Allow HTTP inbound from CloudFront origin-facing IPs only"
  vpc_id      = var.vpc_id

  tags = {
    Name        = "${var.project_name}-alb-cf-${var.environment}"
    Project     = var.project_name
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cloudfront_http" {
  security_group_id  = aws_security_group.alb_cloudfront_only.id
  prefix_list_id     = data.aws_ec2_managed_prefix_list.cloudfront.id
  from_port          = 80
  to_port            = 80
  ip_protocol        = "tcp"
  description        = "Allow HTTP from CloudFront origin-facing prefix list"
}

resource "aws_vpc_security_group_egress_rule" "allow_all" {
  security_group_id = aws_security_group.alb_cloudfront_only.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all outbound traffic"
}

# Managed cache policy: CachingDisabled
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# Managed origin request policy: AllViewer
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

locals {
  has_custom_domain = var.cloudfront_domain != "" && var.acm_certificate_arn != ""
}

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  comment         = "${var.project_name}-${var.environment}"
  is_ipv6_enabled = true
  price_class     = "PriceClass_All"

  aliases = local.has_custom_domain ? [var.cloudfront_domain] : []

  origin {
    domain_name = var.alb_dns_name
    origin_id   = "alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "X-CF-Secret"
      value = random_password.cf_origin_secret.result
    }
  }

  default_cache_behavior {
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "alb"
    viewer_protocol_policy   = "https-only"
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  dynamic "viewer_certificate" {
    for_each = local.has_custom_domain ? [1] : []
    content {
      acm_certificate_arn      = var.acm_certificate_arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1.2_2021"
    }
  }

  dynamic "viewer_certificate" {
    for_each = local.has_custom_domain ? [] : [1]
    content {
      cloudfront_default_certificate = true
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name        = "${var.project_name}-cf-${var.environment}"
    Project     = var.project_name
    Environment = var.environment
  }
}
