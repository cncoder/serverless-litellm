# Claude Code 配置指南

通过 LiteLLM 代理使用 Claude Code，后端为 AWS Bedrock，**无需 Anthropic 官方 API Key**。

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

## 工作原理

```
Claude Code → ANTHROPIC_BASE_URL/v1/messages → LiteLLM → AWS Bedrock
```

- Claude Code 使用 Anthropic SDK，调用 `{ANTHROPIC_BASE_URL}/v1/messages`
- LiteLLM 的 `/v1/messages` 端点完全兼容 Anthropic Messages API 格式
- LiteLLM 将请求路由到对应的 AWS Bedrock 模型
- **不需要**配置 `/anthropic` pass-through，**不需要**真实 Anthropic API Key

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
