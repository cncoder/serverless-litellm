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

> 详细文档：https://code.claude.com/docs/en/quickstart

---

## 配置

将以下内容写入 `~/.claude/settings.json`，**替换 2 个值**即可使用：

```jsonc
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": {
    "ANTHROPIC_BASE_URL": "https://<YOUR_LITELLM_DOMAIN>",   // ← 必填
    "ANTHROPIC_API_KEY": "<YOUR_LITELLM_KEY>",               // ← 必填
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "128000",               // ← 可选：最大输出 token
    "CLAUDE_CODE_EFFORT_LEVEL": "medium",                    // ← 可选：推理深度
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"              // ← 可选：多 agent 协作
  },
  "model": "claude-sonnet-4-6",
  "smallFastModel": "claude-haiku-4-5"
}
```

> ⚠️ `ANTHROPIC_BASE_URL` 不要加 `/v1` 后缀 — Claude Code 会自动拼接 `/v1/messages`

验证：

```bash
claude --print "hello world"
```

---

## VS Code / Cursor 集成

VS Code 扩展**共享** `~/.claude/settings.json`，不需要单独配置 API 地址和 Key。

只需在 VS Code 设置中补充两项：

### Step 1：VS Code 设置

打开 VS Code → `Cmd+Shift+P` → `Preferences: Open User Settings (JSON)`，添加：

```json
{
  "claudeCode.disableLoginPrompt": true,
  "claudeCode.selectedModel": "claude-sonnet-4-6"
}
```

- `disableLoginPrompt` — 跳过 Anthropic 登录提示（使用第三方 provider 必须开启）
- `selectedModel` — 新对话默认模型（也可以在对话中用 `/model` 切换）

### Step 2：确认 `~/.claude/settings.json`

确保上方「配置」段落中的 `~/.claude/settings.json` 已正确配置。VS Code 扩展和 CLI **共享这个文件**。

### ⚠️ 常见问题：扩展仍然走 Bedrock 直连

如果机器上配置了 AWS CLI（`~/.aws/credentials`），扩展可能**自动检测到 AWS 环境并走 Bedrock 直连**，忽略 LiteLLM 配置。

**排查步骤**：
```bash
# 检查是否有 Bedrock 相关残留配置
grep -E 'BEDROCK|AWS_REGION|ANTHROPIC_MODEL' ~/.claude/settings.json

# 检查 VS Code 设置是否有冲突
grep -rE 'BEDROCK|AWS_REGION' ~/Library/Application\ Support/Code/User/settings.json
```

**解决**：从 `~/.claude/settings.json` 中删除 `CLAUDE_CODE_USE_BEDROCK`、`AWS_REGION`、`ANTHROPIC_MODEL` 等字段。详见下方「从 Bedrock 直连迁移」。

### 配置优先级

| 优先级 | 位置 | 作用 |
|--------|------|------|
| 1（最高） | `~/.claude/settings.json` 的 `env` | API 地址、Key、环境变量 |
| 2 | VS Code `claudeCode.*` 设置 | 模型选择、UI 行为 |
| 3 | Shell 环境变量 | 被 settings.json 覆盖 |

> **关键**：`claudeCode.apiBaseUrl` 和 `claudeCode.apiKey` 这两个 VS Code 设置**不存在**。API 配置只能通过 `~/.claude/settings.json` 的 `env` 字段设置。

---

## 可用模型

| 模型参数 | 说明 |
|---------|------|
| `claude-opus-4-6` | Opus 4.6（最新最强） |
| `claude-opus-4-1` | Opus 4.1 |
| `claude-sonnet-4-6` | **Sonnet 4.6（推荐默认）** |
| `claude-haiku-4-5` | Haiku 4.5（最快最便宜） |

短名也可以：`opus` / `sonnet` / `haiku`

> 完整列表（含 Opus 4.5、Sonnet 4.5/3.7、带日期后缀、Bedrock 格式）→ [models.md](models.md)

---

## 工作原理

```
Claude Code → ANTHROPIC_BASE_URL/v1/messages → LiteLLM → AWS Bedrock
```

- Claude Code 使用 Anthropic Messages API 格式发请求
- LiteLLM 转换并路由到 Bedrock 后端
- 不需要真实 Anthropic API Key，LiteLLM Key 即可
- 服务端 `drop_params: true` 自动处理不兼容参数（如 `eager_input_streaming`）

---

## Prompt Caching

**自动生效 ✅** — 无需额外配置。

Claude Code 内部使用 block-level `cache_control`，通过 LiteLLM → Bedrock 链路自动启用 prompt caching。

| 请求 | cache_write | cache_read | 说明 |
|------|-------------|------------|------|
| 首次 | 2860 | 0 | 写入缓存 |
| 重复前缀 | 0 | 2860 | **~90% input 成本节省** |
| 不同 user msg | 0 | 2860 | system prefix 命中 |

**Bedrock 原生支持**（[AWS 文档](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html)）：
- 所有 Claude 模型，最多 4 个 cache checkpoint
- 默认 5 分钟 TTL（Opus 4.5/Sonnet 4.5/Haiku 4.5 支持 1 小时 TTL）
- Cache read = 基础 input 的 10%，cache write = 125%

---

## Troubleshooting

### CC 仍走 Bedrock 直连（`400 The provided model identifier is invalid`）

Claude Code 会**自动检测 AWS 环境**。如果检测到以下任意一项，它会绕过 `ANTHROPIC_BASE_URL` 直连 Bedrock：

**排查清单**（按优先级检查）：

```bash
# 1. 检查 shell 环境变量（最常见！）
echo $CLAUDE_CODE_USE_BEDROCK
echo $AWS_REGION

# 2. 检查 shell 配置文件（.zshrc / .bashrc / .bash_profile）
grep -n 'CLAUDE_CODE_USE_BEDROCK\|AWS_REGION' ~/.zshrc ~/.bashrc ~/.bash_profile 2>/dev/null

# 3. 检查 settings.json
grep -E 'BEDROCK|AWS_REGION|ANTHROPIC_MODEL' ~/.claude/settings.json

# 4. 检查 VS Code 设置
grep -E 'BEDROCK|AWS_REGION' ~/Library/Application\ Support/Code/User/settings.json 2>/dev/null
```

**解决**：删除所有匹配项，然后 `source ~/.zshrc` + 重启 VS Code。详见下方「从 Bedrock 直连迁移」。

> ⚠️ 很多用户在 `.zshrc` 中 `export CLAUDE_CODE_USE_BEDROCK=1` 后忘了删，这会覆盖所有其他配置。

### `eager_input_streaming` 报错

→ 确保 LiteLLM ConfigMap 中 `drop_params: true`（本项目默认已启用）。

### 模型名 404

→ 确认模型名在 [models.md](models.md) 列表中。如需新增别名，在 ConfigMap `model_list` 中添加条目。

> 更多场景 → [troubleshooting.md](troubleshooting.md)

---

## 从 Bedrock 直连迁移

如果之前直接对接 Bedrock（非 LiteLLM），`settings.json` 中以下字段**必须删除**：

| 必须删除的字段 | 原因 |
|--------------|------|
| `CLAUDE_CODE_USE_BEDROCK` | 强制走 Bedrock SDK，忽略 `ANTHROPIC_BASE_URL` |
| `AWS_REGION` | CC 检测到 AWS 环境会自动走 Bedrock |
| `ANTHROPIC_MODEL` | Bedrock 模型 ID 格式，与 LiteLLM 模型名冲突 |
| `CLAUDE_CODE_SUBAGENT_MODEL` | 同上 |
| `CLAUDE_CODE_SMALL_FAST_MODEL` | 同上（改用顶层 `smallFastModel`）|

### ⚠️ 三个地方都要清理

| 位置 | 检查命令 | 说明 |
|------|---------|------|
| **Shell 配置** | `grep -n BEDROCK ~/.zshrc ~/.bashrc` | `.zshrc` 里的 `export` 最容易被遗忘 |
| **settings.json** | `grep BEDROCK ~/.claude/settings.json` | CC 专属配置文件 |
| **VS Code 设置** | `grep BEDROCK ~/Library/.../settings.json` | `claudeCode.environmentVariables` |

> Shell `export` 和 settings.json `env` **同时生效时，settings.json 优先**。但 shell 变量仍会被 CC 检测到用于 AWS 环境判断。**两边都要清理。**

### 迁移 Diff

```diff
  "env": {
-   "CLAUDE_CODE_USE_BEDROCK": "1",
-   "AWS_REGION": "us-west-2",
-   "ANTHROPIC_MODEL": "us.anthropic.claude-opus-4-6-v1",
-   "CLAUDE_CODE_SUBAGENT_MODEL": "global.anthropic.claude-sonnet-4-5-20250929-v1:0",
-   "CLAUDE_CODE_SMALL_FAST_MODEL": "claude-haiku-4-5-20241022",
+   "ANTHROPIC_BASE_URL": "https://<YOUR_LITELLM_DOMAIN>",
+   "ANTHROPIC_API_KEY": "<YOUR_LITELLM_KEY>",
    ...
  },
- "model": "us.anthropic.claude-sonnet-4-6",
+ "model": "claude-sonnet-4-6",
+ "smallFastModel": "claude-haiku-4-5"
```

---

## 参考文档

- [Claude Code 快速开始](https://code.claude.com/docs/en/quickstart)
- [Claude Code LLM Gateway 配置](https://code.claude.com/docs/en/llm-gateway)
- [LiteLLM + Claude API](https://docs.litellm.ai/docs/tutorials/claude_responses_api)
- [Prompt Caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
