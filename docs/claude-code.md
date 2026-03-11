# Claude Code 配置指南

通过 LiteLLM 代理使用 Claude Code，后端为 AWS Bedrock，**无需 Anthropic 官方 API Key**。

---

## 安装 Claude Code

```bash
# macOS / Linux / WSL
curl -fsSL https://claude.ai/install.sh | bash

# Homebrew
brew install claude-code

# Windows PowerShell
irm https://claude.ai/install.ps1 | iex
```

> 详细安装文档及使用指南：https://code.claude.com/docs/en/quickstart

---

## 配置

只需设置两个环境变量，Claude Code 即可通过 LiteLLM 代理访问 Bedrock：

```bash
export ANTHROPIC_BASE_URL="https://<YOUR_LITELLM_DOMAIN>"
export ANTHROPIC_API_KEY="<YOUR_LITELLM_KEY>"

# 验证连接
claude --print "hello"
```

### 持久化配置（~/.claude.json）

将以下内容写入 `~/.claude.json`，重启终端后无需重新 export：

```json
{
  "primaryProvider": "anthropic",
  "anthropicApiKey": "<YOUR_LITELLM_KEY>",
  "anthropicBaseUrl": "https://<YOUR_LITELLM_DOMAIN>"
}
```

---

## 工作原理

```
Claude Code → ANTHROPIC_BASE_URL/v1/messages → LiteLLM → AWS Bedrock
```

- Claude Code 使用 Anthropic Messages API 格式发请求
- LiteLLM 转换并路由到 Bedrock 后端
- 不需要真实 Anthropic API Key，LiteLLM Master Key 即可
- 服务端 `drop_params: true` 自动处理不兼容参数（如 `eager_input_streaming`）

---

## 指定模型

```bash
# 默认模型（claude-sonnet-4-6）
claude

# 指定其他模型
claude --model claude-opus-4-6      # Opus 4.6
claude --model claude-sonnet-4-5    # Sonnet 4.5
claude --model claude-haiku-4-5     # Haiku 4.5（快速）
```

会话内切换：

```
/model claude-opus-4-6
```

---

## 可用模型列表

| 模型参数 | Bedrock 后端 | 说明 |
|---------|------------|------|
| `claude-sonnet-4-6` | `us.anthropic.claude-sonnet-4-6` | **默认**，最新 Sonnet |
| `claude-opus-4-6` | `us.anthropic.claude-opus-4-6-v1` | Opus 4.6 |
| `claude-opus-4-5` | `global.anthropic.claude-opus-4-5-*` | Opus 4.5 |
| `claude-sonnet-4-5` | `global.anthropic.claude-sonnet-4-5-*` | Sonnet 4.5 |
| `claude-haiku-4-5` | `global.anthropic.claude-haiku-4-5-*` | Haiku 4.5 |
| `claude-sonnet-3-7` | `us.anthropic.claude-3-7-sonnet-*` | Sonnet 3.7 |
| `claude-sonnet-3-5` | `us.anthropic.claude-3-5-sonnet-*` | Sonnet 3.5 |

> 完整列表：`curl -s https://<domain>/v1/models -H "Authorization: Bearer <key>" | jq '.data[].id'`

---

## 验证配置

```bash
# 1. 健康检查
curl -s https://<YOUR_LITELLM_DOMAIN>/health/liveliness
# 期望输出: "I'm alive!"

# 2. 列出可用模型
curl -s https://<YOUR_LITELLM_DOMAIN>/v1/models \
  -H "Authorization: Bearer <YOUR_LITELLM_KEY>" | jq '.data | length'

# 3. 测试 Claude Code
claude --print "hello world"
```

---

## EC2 快速部署脚本

在新 EC2 实例（Amazon Linux 2023）上一键安装 Claude Code 并配置 LiteLLM：

```bash
# 替换以下变量
LITELLM_URL="https://<YOUR_LITELLM_DOMAIN>"
LITELLM_KEY="<YOUR_LITELLM_KEY>"

# 安装 Node.js 22 + Claude Code
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh"
nvm install 22 && nvm use 22
npm install -g @anthropic-ai/claude-code

# 配置
cat > ~/.claude.json << EOF
{
  "primaryProvider": "anthropic",
  "anthropicApiKey": "${LITELLM_KEY}",
  "anthropicBaseUrl": "${LITELLM_URL}"
}
EOF

cat >> ~/.bashrc << EOF
export ANTHROPIC_BASE_URL="${LITELLM_URL}"
export ANTHROPIC_API_KEY="${LITELLM_KEY}"
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
EOF

echo "Done! Run: claude --print 'hello'"
```

---

## Troubleshooting

### `eager_input_streaming` 报错

```
litellm.BadRequestError: ... "eager_input_streaming" is not permitted
```

**原因**：Claude Code SDK 发送了 `eager_input_streaming` 参数，Bedrock 不支持。

**解决**：确保 ConfigMap 中 `litellm_settings.drop_params` 设为 `true`（本项目默认已启用）。

### 模型名不匹配 (404 / model not found)

```
Model "claude-haiku-4-5-20251001" not found
```

**原因**：Claude Code 内部可能使用带日期后缀的模型名。

**解决**：在 ConfigMap 中配置独立的 `model_name` 或 `model_group_alias` 映射（本项目已预配置）。

### CloudFront 返回 404

**原因**：CloudFront 的 `Host` header 与 Ingress 的 host 规则不匹配。

**解决**：添加 `host: *` 的 Ingress 规则（本项目 `kubernetes/ingress-http.yaml` 已包含）。

---

## 参考文档

- [Claude Code 快速开始](https://code.claude.com/docs/en/quickstart)
- [Claude Code LLM Gateway 配置](https://code.claude.com/docs/en/llm-gateway)
- [LiteLLM + Claude API](https://docs.litellm.ai/docs/tutorials/claude_responses_api)
