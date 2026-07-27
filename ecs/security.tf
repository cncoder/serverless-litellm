# ---------------------------------------------------------------------------
# 安全组：ALB 只接受 CloudFront，Fargate task 只接受 ALB
# 暴露红线：ALB 入站禁止 0.0.0.0/0，仅放 CloudFront origin-facing prefix list
# ---------------------------------------------------------------------------
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# 随机 origin secret：CloudFront 注入 X-CF-Secret 头，ALB 侧可选校验，防绕过 CF 直连 ALB
resource "random_password" "cf_origin_secret" {
  length  = 48
  special = false
}

# --- ALB SG：入站仅 CloudFront prefix list（80）---
resource "aws_security_group" "alb" {
  name_prefix = "${local.name}-alb-"
  description = "ALB ingress from CloudFront origin-facing prefix list only"
  vpc_id      = aws_vpc.main.id
  lifecycle { create_before_destroy = true }
  tags = merge(local.tags, { Name = "${local.name}-alb-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "HTTP from CloudFront origin-facing IPs only"
}

resource "aws_vpc_security_group_egress_rule" "alb_all_out" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Fargate task SG：入站仅来自 ALB SG ---
resource "aws_security_group" "task" {
  name_prefix = "${local.name}-task-"
  description = "Fargate task ingress from ALB SG only"
  vpc_id      = aws_vpc.main.id
  lifecycle { create_before_destroy = true }
  tags = merge(local.tags, { Name = "${local.name}-task-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  security_group_id            = aws_security_group.task.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 4000
  to_port                      = 4000
  ip_protocol                  = "tcp"
  description                  = "LiteLLM 4000 from ALB only"
}

resource "aws_vpc_security_group_egress_rule" "task_all_out" {
  security_group_id = aws_security_group.task.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound to Bedrock / bedrock-mantle / ECR / logs"
}
