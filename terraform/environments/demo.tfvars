# Demo environment - us-west-2
aws_region         = "us-west-2"
environment        = "demo"
create_vpc         = true
vpc_cidr           = "10.4.0.0/16"
availability_zones = ["us-west-2a", "us-west-2b"]
eks_version        = "1.31"

# CloudFront - enable after ALB is ready
enable_cloudfront = false
# alb_dns_name                 = ""  # Fill after first deploy (kubectl get ingress -n litellm)
# cloudfront_acm_certificate_arn = ""  # ACM cert in us-east-1 (optional, for custom domain)
# cloudfront_domain              = ""  # Custom domain (optional, requires ACM cert)
