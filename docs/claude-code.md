# Claude Code 配置指南

通过 LiteLLM 代理使用 Claude Code，后端为 AWS Bedrock，**无需 Anthropic 官方 API Key**。

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

## 可用模型

| 模型参数 | 说明 |
|---------|------|
| `claude-opus-4-6` | Opus 4.6（最新最强） |
| `claude-opus-4-1` | Opus 4.1 |
| `claude-sonnet-4-6` | **Sonnet 4.6（推荐默认）** |
| `claude-haiku-4-5` | Haiku 4.5（最快最便宜） |

短名也可以：`opus` / `sonnet` / `haiku`

> 完整列表（含 Opus 4.5、Sonnet 4.5/3.7/3.5、带日期后缀、Bedrock 格式）→ [models.md](models.md)

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

## 从 Bedrock 直连迁移

如果之前直接对接 Bedrock（非 LiteLLM），`settings.json` 中以下字段**必须删除**：

| 必须删除的字段 | 原因 |
|--------------|------|
| `CLAUDE_CODE_USE_BEDROCK` | 强制走 Bedrock SDK，忽略 `ANTHROPIC_BASE_URL` |
| `AWS_REGION` | CC 检测到 AWS 环境会自动走 Bedrock |
| `ANTHROPIC_MODEL` | Bedrock 模型 ID 格式，与 LiteLLM 模型名冲突 |
| `CLAUDE_CODE_SUBAGENT_MODEL` | 同上 |
| `CLAUDE_CODE_SMALL_FAST_MODEL` | 同上（改用顶层 `smallFastModel`）|

### ⚠️ settings.json `env` 优先级高于 shell `export`

即使你在终端 `export ANTHROPIC_BASE_URL=...`，如果 settings.json 里有 `CLAUDE_CODE_USE_BEDROCK=1`，CC 仍走 Bedrock。**必须从 settings.json 中删除冲突字段**。

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

**CC 仍走 Bedrock 直连**（`400 The provided model identifier is invalid`）：
```bash
grep -E 'BEDROCK|AWS_REGION|ANTHROPIC_MODEL' ~/.claude/settings.json
```
→ 删除匹配的字段。详见「从 Bedrock 直连迁移」。

**`eager_input_streaming` 报错**：
→ 确保 LiteLLM ConfigMap 中 `drop_params: true`（本项目默认已启用）。

**模型名 404**：
→ 确认模型名在 [models.md](models.md) 列表中。如需新增别名，在 ConfigMap `model_list` 中添加条目。

> 更多场景 → [troubleshooting.md](troubleshooting.md)

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

## 参考文档

- [Claude Code 快速开始](https://code.claude.com/docs/en/quickstart)
- [Claude Code LLM Gateway 配置](https://code.claude.com/docs/en/llm-gateway)
- [LiteLLM + Claude API](https://docs.litellm.ai/docs/tutorials/claude_responses_api)
- [Prompt Caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
