# ---------------------------------------------------------------------------
# ECR：存 litellm 镜像
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "litellm" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true # 测试栈：destroy 时连同镜像一起删
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.tags
}
