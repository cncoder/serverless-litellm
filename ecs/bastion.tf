# ---------------------------------------------------------------------------
# 堡垒机 EC2：在 AWS 内网做运维（build/push 镜像、跑 agent 对接测试）
# SSH 仅对指定出口 IP 开放（暴露红线：绝不 0.0.0.0/0）
# ---------------------------------------------------------------------------
variable "bastion_allowed_cidr" {
  description = "允许 SSH 到堡垒机的 CIDR（当前出口 IP/32）"
  type        = string
  default     = "113.110.215.200/32"
}

variable "enable_bastion" {
  description = "是否创建堡垒机 EC2"
  type        = bool
  default     = true
}

data "aws_ssm_parameter" "al2023_amd64" {
  count = var.enable_bastion ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "bastion" {
  count       = var.enable_bastion ? 1 : 0
  name_prefix = "${local.name}-bastion-"
  description = "Bastion SSH from allowed IP only"
  vpc_id      = aws_vpc.main.id
  lifecycle { create_before_destroy = true }
  tags = merge(local.tags, { Name = "${local.name}-bastion-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  count             = var.enable_bastion ? 1 : 0
  security_group_id = aws_security_group.bastion[0].id
  cidr_ipv4         = var.bastion_allowed_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH from allowed egress IP only"
}

resource "aws_vpc_security_group_egress_rule" "bastion_out" {
  count             = var.enable_bastion ? 1 : 0
  security_group_id = aws_security_group.bastion[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# 堡垒机用的 IAM：ECR push + Bedrock full + mantle（当运维机跑测试）
resource "aws_iam_role" "bastion" {
  count = var.enable_bastion ? 1 : 0
  name  = "${local.name}-bastion"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "bastion_ecr" {
  count      = var.enable_bastion ? 1 : 0
  role       = aws_iam_role.bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# SSM Session Manager：无需 SSH key / 无需开 22 端口即可连入
resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  count      = var.enable_bastion ? 1 : 0
  role       = aws_iam_role.bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "bastion_bedrock" {
  count      = var.enable_bastion ? 1 : 0
  role       = aws_iam_role.bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
}

resource "aws_iam_role_policy" "bastion_mantle" {
  count = var.enable_bastion ? 1 : 0
  name  = "mantle-and-secrets"
  role  = aws_iam_role.bastion[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["bedrock-mantle:*"], Resource = "*" },
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [aws_secretsmanager_secret.master_key.arn] }
    ]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  count = var.enable_bastion ? 1 : 0
  name  = "${local.name}-bastion"
  role  = aws_iam_role.bastion[0].name
  tags  = local.tags
}

resource "aws_instance" "bastion" {
  count                       = var.enable_bastion ? 1 : 0
  ami                         = data.aws_ssm_parameter.al2023_amd64[0].value
  instance_type               = "m7i-flex.large" # 非 T 系列（避免 burst 耗尽假性变慢）
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.bastion[0].id]
  iam_instance_profile        = aws_iam_instance_profile.bastion[0].name
  associate_public_ip_address = true
  key_name                    = var.bastion_key_name != "" ? var.bastion_key_name : null

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y docker git
    systemctl enable --now docker
    usermod -aG docker ec2-user
  EOF

  tags = merge(local.tags, { Name = "${local.name}-bastion" })
}

variable "bastion_key_name" {
  description = "EC2 key pair 名（SSH 用）；留空则只能走 SSM"
  type        = string
  default     = ""
}

output "bastion_public_ip" {
  value = var.enable_bastion ? aws_instance.bastion[0].public_ip : null
}

output "bastion_instance_id" {
  value = var.enable_bastion ? aws_instance.bastion[0].id : null
}

output "bastion_ssm_cmd" {
  description = "用 SSM 连堡垒机（无需 SSH key/开 22 端口）"
  value       = var.enable_bastion ? "aws ssm start-session --target ${aws_instance.bastion[0].id} --region ${var.aws_region}" : null
}
