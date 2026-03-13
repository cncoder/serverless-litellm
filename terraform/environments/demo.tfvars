# Demo environment - us-west-2 with new VPC and CloudFront
aws_region         = "us-west-2"
environment        = "demo"
create_vpc         = true
availability_zones = ["us-west-2a", "us-west-2b"]

# CloudFront
enable_cloudfront = true
# alb_dns_name                 = ""  # Fill after first deploy (kubectl get ingress -n litellm)
# cloudfront_acm_certificate_arn = ""  # ACM cert in us-east-1 (optional, for custom domain)
# cloudfront_domain              = ""  # Custom domain (optional, requires ACM cert)
