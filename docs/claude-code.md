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

## 快速开始（export 方式）

```bash
export ANTHROPIC_BASE_URL="https://<YOUR_LITELLM_DOMAIN>"
export ANTHROPIC_API_KEY="<YOUR_LITELLM_KEY>"

claude
```

**示例**（使用本项目部署的公共 Demo 端点，仅供测试）：

```bash
export ANTHROPIC_BASE_URL="https://litellm.example.com"
export ANTHROPIC_API_KEY="sk-xxxxxxxxxxxxxxxxxxxx"

# 验证连接
claude --print "hello"
```

---

## ~/.claude.json 配置（持久化）

将以下内容写入 `~/.claude.json`，重启后无需重新 export：

```json
{
  "primaryProvider": "anthropic",
  "anthropicApiKey": "<YOUR_LITELLM_KEY>",
  "anthropicBaseUrl": "https://<YOUR_LITELLM_DOMAIN>"
}
```

---

## 方式二：Bedrock Pass-through

通过 LiteLLM 的 pass-through 端点，将请求透传到 AWS Bedrock 原生 API。
适用于需要 Bedrock 原生 API 兼容性的场景。

**前置条件**：LiteLLM ConfigMap 中 `litellm_settings.enable_passthrough_endpoints` 必须为 `true`。

### export 方式

```bash
export ANTHROPIC_BEDROCK_BASE_URL="https://<YOUR_LITELLM_DOMAIN>/bedrock"
export CLAUDE_CODE_SKIP_BEDROCK_AUTH=1
export CLAUDE_CODE_USE_BEDROCK=1
export ANTHROPIC_API_KEY="<YOUR_LITELLM_KEY>"

claude
```

### ~/.claude.json 配置（持久化）

```json
{
  "primaryProvider": "bedrock",
  "bedrockBaseUrl": "https://<YOUR_LITELLM_DOMAIN>/bedrock",
  "anthropicApiKey": "<YOUR_LITELLM_KEY>"
}
```

同时在 shell profile 中设置：

```bash
export CLAUDE_CODE_SKIP_BEDROCK_AUTH=1
export CLAUDE_CODE_USE_BEDROCK=1
```

> 官方文档：https://code.claude.com/docs/en/llm-gateway

---

## 工作原理

### 方式一（Unified Endpoint）
```
Claude Code → ANTHROPIC_BASE_URL/v1/messages → LiteLLM → AWS Bedrock
```

### 方式二（Bedrock Pass-through）
```
Claude Code → ANTHROPIC_BEDROCK_BASE_URL/{region}/model/{model}/... → LiteLLM → AWS Bedrock
```

- 方式一：Claude Code 使用 Anthropic SDK，调用 `{ANTHROPIC_BASE_URL}/v1/messages`，LiteLLM 完全兼容 Anthropic Messages API
- 方式二：Claude Code 使用 Bedrock SDK，请求被 LiteLLM 透传到 Bedrock 原生 API
- 两种方式都不需要真实 Anthropic API Key，LiteLLM Master Key 即可
- **推荐方式一**，配置更简单；方式二适合需要 Bedrock 原生兼容性的场景

---

## 指定模型

```bash
# 默认模型（claude-sonnet-4-6，映射到 Bedrock us inference profile）
claude

# 指定其他模型
claude --model claude-opus-4-6-us      # Opus 4.6 US
claude --model claude-opus-4-6-global  # Opus 4.6 Global
claude --model claude-sonnet-4-5       # Sonnet 4.5
claude --model claude-haiku-4-5        # Haiku 4.5
```

会话内切换：

```bash
claude
/model claude-opus-4-6-us
```

---

## 可用模型列表

| 模型参数 | Bedrock 后端 | 说明 |
|---------|------------|------|
| `claude-sonnet-4-6` | `us.anthropic.claude-sonnet-4-6` | **默认**，最新 Sonnet |
| `claude-sonnet-4-6-us` | `us.anthropic.claude-sonnet-4-6` | Sonnet 4.6 US profile |
| `claude-sonnet-4-6-global` | `global.anthropic.claude-sonnet-4-6` | Sonnet 4.6 Global |
| `claude-opus-4-6` | `us.anthropic.claude-opus-4-6-v1` | Opus 4.6 |
| `claude-opus-4-6-us` | `us.anthropic.claude-opus-4-6-v1` | Opus 4.6 US profile |
| `claude-sonnet-4-5` | `global.anthropic.claude-sonnet-4-5-*` | Sonnet 4.5 |
| `claude-haiku-4-5` | `global.anthropic.claude-haiku-4-5-*` | Haiku 4.5（快速）|

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

# 3. 测试 API 调用
curl -s -X POST https://<YOUR_LITELLM_DOMAIN>/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: <YOUR_LITELLM_KEY>" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"hello"}],"max_tokens":10}'

# 4. 测试 Claude Code
claude --print "hello world"
```

---

## EC2 快速部署脚本

在新 EC2 实例（Amazon Linux 2023）上一键安装 Claude Code 并配置 LiteLLM：

```bash
# 替换以下变量后执行
LITELLM_URL="https://<YOUR_LITELLM_DOMAIN>"
LITELLM_KEY="<YOUR_LITELLM_KEY>"

# 安装 Node.js 22 + Claude Code
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh"
nvm install 22 && nvm use 22
npm install -g @anthropic-ai/claude-code

# 配置 LiteLLM
cat > ~/.claude.json << EOF
{
  "primaryProvider": "anthropic",
  "anthropicApiKey": "${LITELLM_KEY}",
  "anthropicBaseUrl": "${LITELLM_URL}"
}
EOF

# 写入 .bashrc 持久化
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
LiteLLM 会自动丢弃后端不支持的参数。

### 模型名不匹配 (404 / model not found)

```
Model "claude-haiku-4-5-20251001" not found
```

**原因**：Claude Code 内部可能使用带日期后缀的模型名（如 `claude-haiku-4-5-20251001`），
而 LiteLLM 配置中的模型名没有后缀（如 `claude-haiku-4-5`）。

**解决**：在 ConfigMap 中配置 `model_group_alias` 映射：

```yaml
model_group_alias:
  claude-haiku-4-5-20251001: claude-haiku-4-5
  claude-sonnet-4-6-20250514: claude-sonnet-4-6
```

### CloudFront 返回 404

**原因**：CloudFront 发送的 `Host` header 是 CloudFront 域名，与 Ingress 中配置的自定义域名不匹配。

**解决**：添加一个不限制 `host` 的 Ingress 规则（参考 `skills/cloudfront-waf-hardening/SKILL.md`），
或在 CloudFront 中配置 Origin 的 Host header 为自定义域名。

---

## 参考文档

- [Claude Code 快速开始](https://code.claude.com/docs/en/quickstart) — 安装、配置、使用指南
- [Claude Code LLM Gateway 配置](https://code.claude.com/docs/en/llm-gateway) — 第三方 LLM 网关集成
- [LiteLLM + Claude Responses API](https://docs.litellm.ai/docs/tutorials/claude_responses_api) — LiteLLM 代理 Claude API 的详细配置
- [LiteLLM Pass-through 端点](https://docs.litellm.ai/docs/pass_through/bedrock) — Bedrock pass-through 配置
