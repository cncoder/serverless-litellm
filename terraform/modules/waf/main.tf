resource "aws_wafv2_web_acl" "main" {
  name        = "${var.project_name}-waf-${var.environment}"
  description = "WAF for LiteLLM ALB - rate limiting + managed rules"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Rule 1: AWS 托管 - 通用规则组 (SQLi, XSS, 已知漏洞)
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
    }
  }

  # Rule 2: Rate limit for LiteLLM API (2000 req/5min/IP)
  rule {
    name     = "RateLimitLiteLLM"
    priority = 2

    action {
      block {
        custom_response {
          response_code = 429
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            field_to_match {
              single_header {
                name = "host"
              }
            }
            positional_constraint = "EXACTLY"
            search_string         = var.litellm_host
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitLiteLLM"
    }
  }

  # Rule 3: Rate limit for bot host (2000 req/5min/IP)
  rule {
    name     = "RateLimitBot"
    priority = 3

    action {
      block {
        custom_response {
          response_code = 429
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            field_to_match {
              single_header {
                name = "host"
              }
            }
            positional_constraint = "EXACTLY"
            search_string         = var.bot_host
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitBot"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-waf-${var.environment}"
  }

  tags = {
    Name        = "${var.project_name}-waf-${var.environment}"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Associate WAF with ALB (done via post-deploy after ALB is created by ingress controller)
# The ALB ARN is not known at Terraform plan time since it's created by the AWS LB Controller.
# WAF association is handled as a post-deploy step.
resource "null_resource" "waf_association" {
  triggers = {
    waf_acl_arn = aws_wafv2_web_acl.main.arn
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for ALB to be created by ingress controller
      echo "Waiting for ALB to be provisioned..."
      for i in $(seq 1 60); do
        ALB_ARN=$(aws elbv2 describe-load-balancers \
          --region ${var.aws_region} \
          --query "LoadBalancers[?contains(LoadBalancerName, 'litellmshared')].LoadBalancerArn" \
          --output text 2>/dev/null || echo "")
        if [ ! -z "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
          echo "Found ALB: $ALB_ARN"
          aws wafv2 associate-web-acl \
            --web-acl-arn ${aws_wafv2_web_acl.main.arn} \
            --resource-arn "$ALB_ARN" \
            --region ${var.aws_region} || true
          echo "WAF associated with ALB"
          break
        fi
        sleep 10
      done
    EOT
  }

  depends_on = [aws_wafv2_web_acl.main]
}
