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

## 方式一：Unified Endpoint（推荐新用户）

适用于**首次接入**或**没有现有 Bedrock 配置**的用户。配置最简单，只需 2 个变量。

### export 方式

```bash
export ANTHROPIC_BASE_URL="https://<YOUR_LITELLM_DOMAIN>"
export ANTHROPIC_API_KEY="<YOUR_LITELLM_KEY>"

claude --print "hello"
```

### settings.json 配置（推荐）

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": {
    "ANTHROPIC_BASE_URL": "https://<YOUR_LITELLM_DOMAIN>",
    "ANTHROPIC_API_KEY": "<YOUR_LITELLM_KEY>"
  },
  "model": "claude-sonnet-4-6"
}
```

### 工作原理

```
Claude Code → ANTHROPIC_BASE_URL/v1/messages → LiteLLM → AWS Bedrock
```

### ⚠️ 从 Bedrock 直连迁移时必须去掉的配置

如果你之前直接对接 Bedrock（非 LiteLLM），`~/.claude/settings.json` 中可能有以下字段，**必须删除**，否则 Claude Code 会绕过 LiteLLM 继续走 Bedrock 直连：

| 必须删除的字段 | 原因 |
|--------------|------|
| `CLAUDE_CODE_USE_BEDROCK` | 强制 Claude Code 使用 Bedrock SDK，忽略 `ANTHROPIC_BASE_URL` |
| `AWS_REGION` | Claude Code 检测到 AWS 环境后会自动走 Bedrock |
| `ANTHROPIC_MODEL` | Bedrock 模型 ID 格式（如 `us.anthropic.claude-opus-4-6-v1`），LiteLLM 不识别 |
| `CLAUDE_CODE_SUBAGENT_MODEL` | 同上，Bedrock 格式的子代理模型 ID |

其他字段（如 `CLAUDE_CODE_MAX_OUTPUT_TOKENS`、`CLAUDE_CODE_EFFORT_LEVEL`、`CLAUDE_PACKAGE_MANAGER` 等）**不影响**，可以保留。

---

## 方式二：Bedrock Pass-through（推荐已有 Bedrock 环境）

适用于**已在使用 Bedrock 直连**的用户。改动最小，保留现有 `CLAUDE_CODE_USE_BEDROCK=1`，只需加 2 个变量。

**前置条件**：LiteLLM ConfigMap 中 `litellm_settings.enable_passthrough_endpoints` 设为 `true`，Ingress 包含 `/bedrock` 路由。

### export 方式

```bash
export ANTHROPIC_BEDROCK_BASE_URL="https://<YOUR_LITELLM_DOMAIN>/bedrock"
export CLAUDE_CODE_SKIP_BEDROCK_AUTH=1
export CLAUDE_CODE_USE_BEDROCK=1
export ANTHROPIC_API_KEY="<YOUR_LITELLM_KEY>"

claude --print "hello"
```

### settings.json 配置（推荐）

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": {
    "ANTHROPIC_BEDROCK_BASE_URL": "https://<YOUR_LITELLM_DOMAIN>/bedrock",
    "ANTHROPIC_API_KEY": "<YOUR_LITELLM_KEY>",
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "CLAUDE_CODE_SKIP_BEDROCK_AUTH": "1"
  },
  "model": "claude-sonnet-4-6"
}
```

### 工作原理

```
Claude Code → Bedrock SDK → /bedrock/{region}/model/{model}/... → LiteLLM → AWS Bedrock
```

### ⚠️ 从 Bedrock 直连迁移时必须去掉的配置

| 必须删除的字段 | 原因 |
|--------------|------|
| `ANTHROPIC_MODEL` | Bedrock 模型 ID 格式（如 `us.anthropic.claude-opus-4-6-v1`），LiteLLM 使用简短名称（如 `claude-sonnet-4-6`）|
| `CLAUDE_CODE_SUBAGENT_MODEL` | 同上 |
| `AWS_REGION` | 可能干扰 LiteLLM 路由，建议删除 |

可以保留的字段：`CLAUDE_CODE_USE_BEDROCK`（方式二需要）、`CLAUDE_CODE_MAX_OUTPUT_TOKENS`、`CLAUDE_CODE_EFFORT_LEVEL` 等。

---

## 三种接入方式对比

| | Bedrock 直连 | 方式一 (Unified) | 方式二 (Pass-through) |
|---|---|---|---|
| 链路 | CC → Bedrock | CC → LiteLLM → Bedrock | CC → LiteLLM → Bedrock |
| 需要 AWS 凭证 | ✅ | ❌ | ❌ |
| 需要 Anthropic API Key | ❌ | ❌（用 LiteLLM Key） | ❌（用 LiteLLM Key） |
| `CLAUDE_CODE_USE_BEDROCK` | `1` | **删除** | `1`（保留） |
| `AWS_REGION` | 需要 | **删除** | **删除** |
| `ANTHROPIC_MODEL` | Bedrock 格式 | **删除** | **删除** |
| 配置改动量 | — | 删 4 加 2 | 删 2 加 2 |
| 适合 | 有 IAM 权限 | 新用户 | **已有 Bedrock 配置** |

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

# 配置（方式一）
cat >> ~/.bashrc << EOF
export ANTHROPIC_BASE_URL="${LITELLM_URL}"
export ANTHROPIC_API_KEY="${LITELLM_KEY}"
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
EOF

source ~/.bashrc
echo "Done! Run: claude --print 'hello'"
```

---

## Troubleshooting

### Claude Code 仍然走 Bedrock 直连

**症状**：

```
API Error (claude-sonnet-4-6): 400 The provided model identifier is invalid.
Try --model to switch to us.anthropic.claude-sonnet-4-5-20250929-v1:0.
```

**原因**：`~/.claude/settings.json` 中的 `env` 字段优先级**高于** shell `export`。如果 settings.json 里有 `CLAUDE_CODE_USE_BEDROCK=1`，即使你 export 了 `ANTHROPIC_BASE_URL`，Claude Code 仍然走 Bedrock。

**排查**：

```bash
# 检查 settings.json
grep -E 'BEDROCK|AWS_REGION|ANTHROPIC_MODEL' ~/.claude/settings.json

# 检查当前环境变量
env | grep -iE 'ANTHROPIC|CLAUDE|BEDROCK|AWS'
```

**解决**：按照上方「从 Bedrock 直连迁移时必须去掉的配置」表格，删除冲突字段。

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

### CloudFront 返回 504 Gateway Timeout

**可能原因**：
1. ALB 没有活跃的 Listener — 检查 `aws elbv2 describe-listeners`
2. Target Group 中的 Pod 不健康 — 检查 `kubectl get pods -n litellm`
3. 安全组未放行 CloudFront IP — ALB SG 需要包含 CloudFront 前缀列表

### CloudFront 返回 404

**原因**：CloudFront 的 `Host` header 与 Ingress 的 host 规则不匹配。

**解决**：添加 `host: *` 的 Ingress 规则（本项目 `kubernetes/ingress-http.yaml` 已包含）。

---

## 参考文档

- [Claude Code 快速开始](https://code.claude.com/docs/en/quickstart)
- [Claude Code LLM Gateway 配置](https://code.claude.com/docs/en/llm-gateway)
- [LiteLLM + Claude API](https://docs.litellm.ai/docs/tutorials/claude_responses_api)
- [LiteLLM Pass-through 端点](https://docs.litellm.ai/docs/pass_through/bedrock)
