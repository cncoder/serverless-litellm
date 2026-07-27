# ---------------------------------------------------------------------------
# ALB：内部编排入口，仅作 CloudFront 的 origin（不对公网直开，SG 已锁 CF prefix list）
# 说明：ALB 本身在公有子网（需可路由回 CloudFront），但入站 SG 只允许 CloudFront，
#       等效于"只通过 CloudFront 提供"。scheme=internet-facing 是为了让 CF 能连到它，
#       真正的访问控制在 SG 层（仅 CloudFront origin-facing prefix list）。
# ---------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = substr("${local.name}-alb", 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  idle_timeout       = 600 # LLM 长响应
  tags               = local.tags
}

resource "aws_lb_target_group" "litellm" {
  name        = substr("${local.name}-tg", 0, 32)
  port        = 4000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # Fargate awsvpc 网络模式
  health_check {
    path                = "/health/liveliness"
    healthy_threshold   = 2
    unhealthy_threshold = 5
    timeout             = 10
    interval            = 30
    matcher             = "200"
  }
  deregistration_delay = 30
  tags                 = local.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  # 默认拒绝：没有 CloudFront 注入的 X-CF-Secret 头就 403，堵死绕过 CF 直连 ALB
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Direct access denied. Use CloudFront."
      status_code  = "403"
    }
  }
  tags = local.tags
}

# 仅当请求带正确的 X-CF-Secret（CloudFront 注入）才转发到 litellm
resource "aws_lb_listener_rule" "cf_only" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.litellm.arn
  }

  condition {
    http_header {
      http_header_name = "X-CF-Secret"
      values           = [random_password.cf_origin_secret.result]
    }
  }
}
