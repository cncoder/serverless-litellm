# Claude Code 配置指南

通过 LiteLLM 代理使用 Claude Code，后端为 AWS Bedrock，**无需 Anthropic 官方 API Key**。

> 安装和快速配置 → [README 快速开始](../README.md#配置-claude-code)

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

Claude Code 内部自动使用 block-level `cache_control`，通过 LiteLLM → Bedrock 全链路透传，实测 **~90% input 成本节省**。

**关键结论**：
- Bedrock 原生支持 prompt caching，所有 Claude 模型，最多 4 个 cache checkpoint
- Claude Code 固定使用 5 分钟 TTL（硬编码 `"type": "ephemeral"`，不可修改）
- Bedrock 对部分模型支持延长到 1 小时，但需要客户端传 `"ttl": "1h"`，CC 目前不支持
- `drop_params: true` 不会影响 cache_control（它是 block-level 参数，不是顶层参数）
- Cache read 成本 = 基础 input × 10%，cache write = 基础 input × 125%

---

## Troubleshooting

### CC 仍走 Bedrock 直连

**症状**：`400 The provided model identifier is invalid` 或模型显示为 `us.anthropic.claude-*` 格式。

**原因**：Claude Code 自动检测 AWS 环境 — 只要发现 `CLAUDE_CODE_USE_BEDROCK=1` 或 `AWS_REGION`，就会绕过 `ANTHROPIC_BASE_URL` 直连 Bedrock。**CLI 和 VS Code 扩展共用同一套检测逻辑。**

**一键排查**：

```bash
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
sed -i '' '/CLAUDE_CODE_USE_BEDROCK/d' ~/.zshrc
sed -i '' '/^export AWS_REGION/d' ~/.zshrc
unset CLAUDE_CODE_USE_BEDROCK AWS_REGION
source ~/.zshrc
```

然后检查 `~/.claude/settings.json`，删除 Bedrock 相关字段。详见 [从 Bedrock 直连迁移](#从-bedrock-直连迁移)。

> ⚠️ **最常见的坑**：`.zshrc` 里的 `export CLAUDE_CODE_USE_BEDROCK=1` 或 `export AWS_REGION=us-west-2`。配过 Bedrock 直连后忘了删，它会覆盖所有其他配置。

### `eager_input_streaming` 报错

```
tools.0.custom.eager_input_streaming: Extra inputs are not permitted
```

→ 确保 LiteLLM ConfigMap 中 `drop_params: true`（本项目默认已启用）。

### `input_examples` 报错

```
tools.3.custom.input_examples: Extra inputs are not permitted
```

→ `drop_params: true` **无法修复**（嵌套在 `tools[]` 内部）。需升级 LiteLLM 至 **≥ v1.81.3**（[PR #19841](https://github.com/BerriAI/litellm/pull/19841)）。

```bash
# 检查当前版本
curl -s https://<YOUR_LITELLM_DOMAIN>/health | jq '.version'
```

### 模型名 404

→ 确认模型名在 [models.md](models.md) 列表中。如需新增别名，在 ConfigMap `model_list` 中添加条目。

---

## 从 Bedrock 直连迁移

如果之前直接对接 Bedrock，需要在**三个位置**清理旧配置：

### 1. Shell 配置文件

```bash
grep -n 'CLAUDE_CODE_USE_BEDROCK\|^export AWS_REGION\|ANTHROPIC_MODEL' ~/.zshrc
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

检查 `claudeCode.environmentVariables` 和 `terminal.integrated.env.osx` 中是否有 Bedrock 相关变量，有则删除。

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

## VS Code / Cursor 扩展

> ⚠️ **VS Code 扩展目前不支持通过 LiteLLM 代理连接**，待官方适配。以下为已知限制：
> - ❌ `claudeCode.apiBaseUrl` / `claudeCode.apiKey` — 设置项不存在
> - ❌ `terminal.integrated.env.osx` — 只影响终端，扩展面板是独立进程
> - ❌ `.vscode/settings.json` — 扩展不从这里读 API 配置
>
> **CLI 可正常使用**。VS Code 扩展需等待 Anthropic 官方支持第三方 API endpoint 配置。

如果你仍想尝试（可能在未来版本生效）：

`~/.claude/settings.json`（全局）或项目根目录 `.claude/settings.json`（项目级）是唯一可能生效的配置路径。

---

## 参考文档

- [Claude Code 快速开始](https://code.claude.com/docs/en/quickstart)
- [Claude Code VS Code 扩展](https://code.claude.com/docs/en/vs-code)
- [Claude Code LLM Gateway 配置](https://code.claude.com/docs/en/llm-gateway)
- [LiteLLM Bedrock 集成](https://docs.litellm.ai/docs/providers/bedrock)
- [Prompt Caching — AWS Bedrock](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html)
