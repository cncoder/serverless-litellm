# ---------------------------------------------------------------------------
# Secrets Manager：仅 master key（LiteLLM 网关认证）
# GPT/Claude 全走 task role 的 IAM SigV4，不使用任何 Bedrock API key / bearer token
# ---------------------------------------------------------------------------
resource "random_password" "master_key" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "master_key" {
  name                    = "${local.name}-master-key"
  description             = "LiteLLM master key (sk-...)"
  recovery_window_in_days = 0 # 允许 destroy 时立即删除（测试栈）
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "master_key" {
  secret_id     = aws_secretsmanager_secret.master_key.id
  secret_string = "sk-${random_password.master_key.result}"
}
