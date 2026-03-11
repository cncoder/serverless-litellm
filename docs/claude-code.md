# Claude Code 配置指南

通过 LiteLLM 代理使用 Claude Code，后端为 AWS Bedrock，**无需 Anthropic 官方 API Key**。

## TL;DR

```bash
# 1. 安装
curl -fsSL https://claude.ai/install.sh | bash

# 2. 写配置（替换 YOUR_LITELLM_DOMAIN 和 YOUR_LITELLM_KEY）
cat > ~/.claude/settings.json << 'EOF'
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://YOUR_LITELLM_DOMAIN",
    "ANTHROPIC_API_KEY": "YOUR_LITELLM_KEY"
  },
  "model": "claude-sonnet-4-6",
  "smallFastModel": "claude-haiku-4-5"
}
EOF

# 3. 确保没有 Bedrock 残留
unset CLAUDE_CODE_USE_BEDROCK AWS_REGION
sed -i '' '/CLAUDE_CODE_USE_BEDROCK/d; /^export AWS_REGION/d' ~/.zshrc 2>/dev/null

# 4. 验证
claude --print "hello world"
```

> 如果之前用过 Bedrock 直连，务必执行第 3 步。详见 [从 Bedrock 直连迁移](#从-bedrock-直连迁移)。

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

## 配置 — CLI

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

> ⚠️ `ANTHROPIC_BASE_URL` **不要加 `/v1` 后缀** — Claude Code 会自动拼接 `/v1/messages`

验证：

```bash
claude --print "hello world"
```

---

## 配置 — VS Code / Cursor

VS Code 扩展和 CLI **共享 `~/.claude/settings.json`**，API 配置只需写一次。

VS Code 侧只需补充两个扩展设置：

```json
// VS Code Settings (Cmd+Shift+P → Preferences: Open User Settings JSON)
{
  "claudeCode.disableLoginPrompt": true,
  "claudeCode.selectedModel": "claude-sonnet-4-6"
}
```

| 设置 | 作用 |
|------|------|
| `disableLoginPrompt` | 跳过 Anthropic 登录（使用第三方 provider **必须开启**） |
| `selectedModel` | 新对话默认模型，也可以在对话中用 `/model` 切换 |

> **`claudeCode.apiBaseUrl` 和 `claudeCode.apiKey` 不存在** — VS Code 扩展没有这两个设置项。API 地址和 Key 只能通过 `~/.claude/settings.json` 配置。
>
> 官方文档：https://code.claude.com/docs/en/vs-code

### 配置优先级

```
~/.claude/settings.json env（最高）
        ↓
VS Code claudeCode.* 设置
        ↓
Shell 环境变量（最低，但会触发 AWS 环境检测！）
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

### CC 仍走 Bedrock 直连

**症状**：`400 The provided model identifier is invalid` 或模型显示为 `us.anthropic.claude-*` 格式。

**原因**：Claude Code 自动检测 AWS 环境 — 只要发现 `CLAUDE_CODE_USE_BEDROCK=1` 或 `AWS_REGION`，就会绕过 `ANTHROPIC_BASE_URL` 直连 Bedrock。**CLI 和 VS Code 扩展共用同一套检测逻辑。**

**一键排查**：

```bash
# 把这段全部复制粘贴执行
echo "=== 1. Shell 环境变量 ==="
echo "CLAUDE_CODE_USE_BEDROCK=$CLAUDE_CODE_USE_BEDROCK"
echo "AWS_REGION=$AWS_REGION"
echo ""
echo "=== 2. Shell 配置文件 (.zshrc / .bashrc) ==="
grep -n 'CLAUDE_CODE_USE_BEDROCK\|^export AWS_REGION' ~/.zshrc ~/.bashrc ~/.bash_profile 2>/dev/null || echo "(clean)"
echo ""
echo "=== 3. ~/.claude/settings.json ==="
grep -E 'BEDROCK|AWS_REGION|ANTHROPIC_MODEL' ~/.claude/settings.json 2>/dev/null || echo "(clean)"
echo ""
echo "=== 4. VS Code 用户设置 ==="
grep -E 'BEDROCK|AWS_REGION' ~/Library/Application\ Support/Code/User/settings.json 2>/dev/null || echo "(clean)"
```

**清理方法**：

```bash
# 删除 .zshrc 中的 Bedrock 配置行
sed -i '' '/CLAUDE_CODE_USE_BEDROCK/d' ~/.zshrc
sed -i '' '/^export AWS_REGION/d' ~/.zshrc

# 清除当前 shell
unset CLAUDE_CODE_USE_BEDROCK AWS_REGION

# 重载
source ~/.zshrc
```

然后检查 `~/.claude/settings.json`，删除 `CLAUDE_CODE_USE_BEDROCK`、`AWS_REGION`、`ANTHROPIC_MODEL` 等字段。详见 [从 Bedrock 直连迁移](#从-bedrock-直连迁移)。

> ⚠️ **最常见的坑**：`.zshrc` 里的 `export CLAUDE_CODE_USE_BEDROCK=1` 或 `export AWS_REGION=us-west-2`。很多用户配过 Bedrock 直连后忘了删，它会覆盖所有其他配置。

### `eager_input_streaming` 报错

→ 确保 LiteLLM ConfigMap 中 `drop_params: true`（本项目默认已启用）。

### 模型名 404

→ 确认模型名在 [models.md](models.md) 列表中。如需新增别名，在 ConfigMap `model_list` 中添加条目。

---

## 从 Bedrock 直连迁移

如果之前直接对接 Bedrock（非 LiteLLM），需要在**三个位置**清理旧配置：

### 1. Shell 配置文件（`.zshrc` / `.bashrc`）

```bash
# 查找
grep -n 'CLAUDE_CODE_USE_BEDROCK\|^export AWS_REGION\|ANTHROPIC_MODEL' ~/.zshrc

# 删除匹配行（备份 .zshrc 后执行）
sed -i '' '/CLAUDE_CODE_USE_BEDROCK/d; /^export AWS_REGION/d; /ANTHROPIC_MODEL/d' ~/.zshrc
source ~/.zshrc
```

### 2. `~/.claude/settings.json`

| 必须删除的字段 | 原因 |
|--------------|------|
| `CLAUDE_CODE_USE_BEDROCK` | 强制走 Bedrock SDK，忽略 `ANTHROPIC_BASE_URL` |
| `AWS_REGION` | CC 检测到 AWS 环境会自动走 Bedrock |
| `ANTHROPIC_MODEL` | Bedrock 模型 ID 格式，与 LiteLLM 模型名冲突 |
| `CLAUDE_CODE_SUBAGENT_MODEL` | 同上 |
| `CLAUDE_CODE_SMALL_FAST_MODEL` | 同上（改用顶层 `smallFastModel`）|

### 3. VS Code 用户设置

检查 `claudeCode.environmentVariables` 中是否有 Bedrock 相关变量，有则删除。

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

同时删除 `.zshrc` 中的：

```diff
- # Claude Code Bedrock Configuration
- export CLAUDE_CODE_USE_BEDROCK=1
- export AWS_REGION=us-west-2
- export CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000
```

将需要保留的选项迁移到 `~/.claude/settings.json` 的 `env` 字段（如 `CLAUDE_CODE_MAX_OUTPUT_TOKENS`）。

---

## 参考文档

- [Claude Code 快速开始](https://code.claude.com/docs/en/quickstart)
- [Claude Code VS Code 扩展](https://code.claude.com/docs/en/vs-code)
- [Claude Code LLM Gateway 配置](https://code.claude.com/docs/en/llm-gateway)
- [LiteLLM + Claude API](https://docs.litellm.ai/docs/tutorials/claude_responses_api)
- [Prompt Caching — AWS Bedrock](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html)
- [Prompt Caching — Anthropic](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
