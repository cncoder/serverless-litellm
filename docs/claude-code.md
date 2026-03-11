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

## 配置（settings.json 一键模板）

将以下内容写入 `~/.claude/settings.json`，**只需替换 2 个值**即可使用：

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": {
    "ANTHROPIC_BASE_URL": "https://<YOUR_LITELLM_DOMAIN>",
    "ANTHROPIC_API_KEY": "<YOUR_LITELLM_KEY>"
  },
  "model": "claude-sonnet-4-6",
  "smallFastModel": "claude-haiku-4-5"
}
```

写好后验证：

```bash
claude --print "hello world"
```

就这么简单。不需要 `CLAUDE_CODE_USE_BEDROCK`、`AWS_REGION`、`AWS_ACCESS_KEY_ID` 等任何 AWS 相关变量。

---

## 完整配置模板（含常用选项）

如果需要更多定制，以下是包含常用选项的完整模板：

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "respectGitignore": true,
  "cleanupPeriodDays": 30,
  "env": {
    "ANTHROPIC_BASE_URL": "https://<YOUR_LITELLM_DOMAIN>",
    "ANTHROPIC_API_KEY": "<YOUR_LITELLM_KEY>",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "128000",
    "CLAUDE_CODE_EFFORT_LEVEL": "medium",
    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "50",
    "CLAUDE_PACKAGE_MANAGER": "pnpm",
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "model": "claude-opus-4-6",
  "smallFastModel": "claude-haiku-4-5"
}
```

> 所有非 LiteLLM 相关的选项（`MAX_OUTPUT_TOKENS`、`EFFORT_LEVEL`、`PACKAGE_MANAGER` 等）可自由添加，不影响 LiteLLM 连接。

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

## 可用模型

以下模型名称均已在 LiteLLM 中注册，可直接用于 `model` 字段或 `--model` 参数：

### 推荐名称

| 模型参数 | 说明 |
|---------|------|
| `claude-opus-4-6` | Opus 4.6（最强） |
| `claude-sonnet-4-6` | **Sonnet 4.6（推荐默认）** |
| `claude-haiku-4-5` | Haiku 4.5（最快最便宜） |
| `claude-opus-4-5` | Opus 4.5 |
| `claude-sonnet-4-5` | Sonnet 4.5 |
| `claude-sonnet-3-7` | Sonnet 3.7 |
| `claude-sonnet-3-5` | Sonnet 3.5 |

### 兼容的别名

以下格式也可以使用（LiteLLM 自动映射）：

| 格式 | 示例 | 映射到 |
|------|------|--------|
| 短名 | `opus` / `sonnet` / `haiku` | 最新版本 |
| 带日期后缀 | `claude-opus-4-6-20250915` | `claude-opus-4-6` |
| Bedrock 格式 | `us.anthropic.claude-opus-4-6-v1` | `claude-opus-4-6` |

> 完整列表：`curl -s https://<domain>/v1/models -H "Authorization: Bearer <key>" | jq '.data[].id'`

---

## 从 Bedrock 直连迁移

如果你之前直接对接 Bedrock（非 LiteLLM），`~/.claude/settings.json` 中可能有以下字段会冲突：

| 必须删除的字段 | 原因 |
|--------------|------|
| `CLAUDE_CODE_USE_BEDROCK` | 强制走 Bedrock SDK，忽略 `ANTHROPIC_BASE_URL` |
| `AWS_REGION` | CC 检测到 AWS 环境会自动走 Bedrock |
| `ANTHROPIC_MODEL` | Bedrock 模型 ID 格式，与 LiteLLM 模型名冲突 |
| `CLAUDE_CODE_SUBAGENT_MODEL` | 同上 |
| `CLAUDE_CODE_SMALL_FAST_MODEL` | 同上（改用顶层 `smallFastModel`）|

### ⚠️ 重要：settings.json 的 `env` 优先级高于 shell `export`

即使你在终端 `export ANTHROPIC_BASE_URL=...`，如果 `settings.json` 里有 `CLAUDE_CODE_USE_BEDROCK=1`，CC 仍然走 Bedrock 直连。**必须从 settings.json 中删除冲突字段**。

### 迁移前后对比

```diff
  "env": {
-   "CLAUDE_CODE_USE_BEDROCK": "1",
-   "AWS_REGION": "us-west-2",
-   "ANTHROPIC_MODEL": "us.anthropic.claude-opus-4-6-v1",
-   "CLAUDE_CODE_SUBAGENT_MODEL": "global.anthropic.claude-sonnet-4-5-20250929-v1:0",
-   "CLAUDE_CODE_SMALL_FAST_MODEL": "claude-haiku-4-5-20241022",
+   "ANTHROPIC_BASE_URL": "https://<YOUR_LITELLM_DOMAIN>",
+   "ANTHROPIC_API_KEY": "<YOUR_LITELLM_KEY>",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "128000",
    "CLAUDE_CODE_EFFORT_LEVEL": "medium",
    ...
  },
- "model": "us.anthropic.claude-sonnet-4-6",
+ "model": "claude-opus-4-6",
+ "smallFastModel": "claude-haiku-4-5"
```

其他字段（`MAX_OUTPUT_TOKENS`、`EFFORT_LEVEL`、`PACKAGE_MANAGER`、`TELEMETRY`、`AGENT_TEAMS` 等）**不影响**，保留即可。

---

## 关于 Prompt Caching

Claude Code 自动管理 prompt caching。LiteLLM 会透传 `cache_control` 相关字段。

> ⚠️ **当前限制**：Prompt caching 目前仅在 Anthropic API 直连和 Azure AI Foundry 上生效。AWS Bedrock 后端暂不支持（官方标注 "coming later"）。这意味着通过 LiteLLM → Bedrock 链路时，caching 字段会被接受但不会产生实际缓存效果。
>
> 参考：https://platform.claude.com/docs/en/build-with-claude/prompt-caching

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

# 4. 指定模型测试
claude --print --model claude-opus-4-6 "hello"
claude --print --model claude-haiku-4-5 "hello"
```

---

## EC2 快速部署脚本

在新 EC2 实例（Amazon Linux 2023）上一键安装并配置：

```bash
# 替换以下变量
LITELLM_URL="https://<YOUR_LITELLM_DOMAIN>"
LITELLM_KEY="<YOUR_LITELLM_KEY>"

# 安装 Node.js 22 + Claude Code
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh"
nvm install 22 && nvm use 22
npm install -g @anthropic-ai/claude-code

# 写入 settings.json（唯一配置文件，无需 export）
mkdir -p ~/.claude
cat > ~/.claude/settings.json << EOF
{
  "\$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": {
    "ANTHROPIC_BASE_URL": "${LITELLM_URL}",
    "ANTHROPIC_API_KEY": "${LITELLM_KEY}"
  },
  "model": "claude-sonnet-4-6",
  "smallFastModel": "claude-haiku-4-5"
}
EOF

# 持久化 NVM
cat >> ~/.bashrc << 'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
EOF

echo "Done! Run: claude --print 'hello'"
```

---

## Troubleshooting

### Claude Code 仍然走 Bedrock 直连

**症状**：
```
API Error (claude-sonnet-4-6): 400 The provided model identifier is invalid.
```

**排查**：
```bash
# 检查 settings.json 中是否有 Bedrock 相关配置
grep -E 'BEDROCK|AWS_REGION|ANTHROPIC_MODEL' ~/.claude/settings.json
```

**解决**：删除 `CLAUDE_CODE_USE_BEDROCK`、`AWS_REGION`、`ANTHROPIC_MODEL` 等字段。详见上方「从 Bedrock 直连迁移」。

### `eager_input_streaming` 报错

```
litellm.BadRequestError: ... "eager_input_streaming" is not permitted
```

**解决**：确保 LiteLLM ConfigMap 中 `litellm_settings.drop_params` 设为 `true`（本项目默认已启用）。

### 模型名不匹配 (404 / model not found)

```
Model "claude-haiku-4-5-20251001" not found
```

**解决**：本项目已预配置所有常用模型名别名。如遇到未覆盖的名称，在 ConfigMap `model_list` 中添加对应条目。

### CloudFront 返回 504 Gateway Timeout

检查：
1. ALB 是否有活跃的 Listener：`aws elbv2 describe-listeners`
2. Pod 是否健康：`kubectl get pods -n litellm`
3. 安全组是否放行 CloudFront IP

### CloudFront 返回 404

**解决**：确保 Ingress 包含 `host: *` 的规则（本项目 `kubernetes/ingress-http.yaml` 已包含）。

---

## 参考文档

- [Claude Code 快速开始](https://code.claude.com/docs/en/quickstart)
- [Claude Code LLM Gateway 配置](https://code.claude.com/docs/en/llm-gateway)
- [LiteLLM + Claude API](https://docs.litellm.ai/docs/tutorials/claude_responses_api)
- [Prompt Caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
