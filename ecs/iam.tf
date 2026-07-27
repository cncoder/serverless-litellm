# ---------------------------------------------------------------------------
# IAM：execution role（拉镜像/写日志/读 secret）+ task role（调 Bedrock + Mantle）
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

# --- Execution role：ECS agent 拉 ECR 镜像、写 CloudWatch、注入 secret ---
resource "aws_iam_role" "execution" {
  name = "${local.name}-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# execution role 需能读 Secrets Manager 里的 master key
resource "aws_iam_role_policy" "execution_secrets" {
  name = "read-secrets"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.master_key.arn]
    }]
  })
}

# --- Task role：容器运行时调用推理 API ---
resource "aws_iam_role" "task" {
  name = "${local.name}-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

# 兼容性关键：task role 给 Bedrock 全权限，保证任意模型（Claude/GPT/多模态/未来新模型）
# 都能经 litellm 调通，不因缺某个细粒度 action 而某模型走不通。
# - AmazonBedrockFullAccess 覆盖 bedrock:* 全部推理/管理动作（含 Converse 多模态）
resource "aws_iam_role_policy_attachment" "task_bedrock_full" {
  role       = aws_iam_role.task.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
}

# bedrock-mantle 是独立服务命名空间，FullAccess 未必涵盖，显式补上（GPT via mantle）
resource "aws_iam_role_policy" "task_mantle" {
  name = "invoke-bedrock-mantle"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "BedrockMantleOpenAIInference"
      Effect = "Allow"
      Action = [
        "bedrock-mantle:CreateInference",
        "bedrock-mantle:CallWithBearerToken",
        "bedrock-mantle:*",
      ]
      Resource = "*"
    }]
  })
}
