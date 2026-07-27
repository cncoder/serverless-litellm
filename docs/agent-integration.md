# Agent 接入指南 — LiteLLM Gateway (fargate 分支)

本文档给出各常见 agent 接入本网关的完整配置。部署本分支后，你只需要两样东西：

- **网关地址**：`https://<cloudfront-domain>`（terraform output `cloudfront_url`）
- **master key**：`sk-...`（`terraform output get_master_key_cmd` 拿到取值命令）

> 本网关只通过 CloudFront 暴露，直连 ALB 会 403。所有推理端点都在 CloudFront 域名下。

---

## 支持的端点

同一份 config、同一个 master key，同时提供四种协议端点（配好 model_list 自动可用）：

| 端点 | 协议 | 谁用 |
|------|------|------|
| `POST /v1/messages` | Anthropic Messages | Claude Code |
| `POST /v1/chat/completions` | OpenAI Chat | OpenClaw / Hermes / 通用 OpenAI SDK |
| `POST /v1/responses` | OpenAI Responses | Codex CLI |
| `POST /bedrock/...` | Bedrock passthrough | 原生 Bedrock SDK |
| `GET /v1/models` | — | 列出所有可用模型 |
| `GET /health/liveliness` | — | 健康检查 |

## 可用模型（短名）

| 短名 | 后端 | 说明 |
|------|------|------|
| `opus-4-8` / `opus` | bedrock/us.anthropic.claude-opus-4-8 | 默认主力 |
| `fable-5` | bedrock/us.anthropic.claude-fable-5 | reasoning 恒开、temperature 固定 |
| `opus-4-6` | bedrock/us.anthropic.claude-opus-4-6-v1 | |
| `sonnet-4-6` / `sonnet` | bedrock/us.anthropic.claude-sonnet-4-6 | 小快模型 / subagent |
| `gpt-5.6-sol` | bedrock_mantle/openai.gpt-5.6-sol | 旗舰推理 |
| `gpt-5.6-terra` | bedrock_mantle/openai.gpt-5.6-terra | 均衡 |
| `gpt-5.6-luna` | bedrock_mantle/openai.gpt-5.6-luna | 快、便宜 |
| `gpt-5.5` | bedrock_mantle/openai.gpt-5.5 | us-east-2 |
| `bedrock/<任意模型>` | 通配 | 任意 Bedrock 模型直调 |

---

## 1. Claude Code

写入 `~/.claude/settings.json`，替换两个值：

```jsonc
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://<cloudfront-domain>",
    "ANTHROPIC_AUTH_TOKEN": "<master-key>",
    "DISABLE_TELEMETRY": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  },
  "model": "opus-4-8",
  "smallFastModel": "sonnet-4-6"
}
```

验证：`claude --print "hello"`。切模型：`claude --model fable-5`。

## 2. Codex CLI（经网关，已实测跑通含真实工具调用）

Codex 走 Responses API。**关键**：codex 0.145 对 gpt-5.6 默认走 "responses-lite" 协议变体
（带 additional_tools / x-openai-internal-codex-responses-lite 等私有字段），LiteLLM/Mantle
不认会报 "stream disconnected"。必须给 codex 一份 `use_responses_lite=false` 的 model catalog。

准备（执行一次，需 jq）：

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh      # 装 codex（若未装）
mkdir -p ~/.codex
curl -fsSL https://raw.githubusercontent.com/openai/codex/rust-v0.145.0/codex-rs/models-manager/models.json \
  | jq '[.models[] | if (.slug|startswith("gpt-5.6")) then .use_responses_lite=false else . end] as $m | .models=$m' \
  > ~/.codex/models-standard-responses.json
```

`~/.codex/config.toml`：

```toml
model = "gpt-5.6-terra"
model_provider = "litellm-gw"
model_catalog_json = "/home/<user>/.codex/models-standard-responses.json"  # 绝对路径
approval_policy = "never"
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false

[features]
remote_models = false     # 无 ChatGPT 登录态环境（EC2 等）必须关，否则连 chatgpt.com 403
plugins = false
apps = false

[model_providers.litellm-gw]
name = "LiteLLM Gateway"
base_url = "https://<cloudfront-domain>/v1"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
supports_websockets = false
request_max_retries = 1
stream_max_retries = 1
stream_idle_timeout_ms = 300000
```

启动 + 验证：

```bash
export OPENAI_API_KEY="<master-key>"
codex exec "print exactly: OK"                    # 纯文本
codex exec "执行 printf hi 并只输出其 stdout"       # 真实工具调用
```

> 备选：不想经网关时，用 Codex 原生 `model_provider = "amazon-bedrock"` 直连 Bedrock Mantle
> （纯 IAM，见 `examples/codex-config.toml` 备选段）。

## 3. OpenClaw

OpenClaw 走 OpenAI 兼容格式。在 openclaw 的模型配置里指向网关：

```jsonc
{
  "provider": "openai",
  "base_url": "https://<cloudfront-domain>/v1",
  "api_key": "<master-key>",
  "model": "opus-4-8"
}
```

## 4. Hermes Agent

同样 OpenAI 兼容 `/v1/chat/completions`：

```bash
export OPENAI_BASE_URL="https://<cloudfront-domain>/v1"
export OPENAI_API_KEY="<master-key>"
# Hermes 配置里 model 填 opus-4-8 / gpt-5.6-terra 等短名
```

---

## 通用调用示例（curl）

### OpenAI Chat（Claude 或 GPT 都行）

```bash
curl https://<cloudfront-domain>/v1/chat/completions \
  -H "Authorization: Bearer <master-key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"opus-4-8","messages":[{"role":"user","content":"hello"}]}'
```

### Responses API（GPT-5.6）

```bash
curl https://<cloudfront-domain>/v1/responses \
  -H "Authorization: Bearer <master-key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-5.6-sol","input":"hello"}'
```

### Anthropic Messages（Claude Code 用的格式）

```bash
curl https://<cloudfront-domain>/v1/messages \
  -H "Authorization: Bearer <master-key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"opus-4-8","max_tokens":100,"messages":[{"role":"user","content":"hello"}]}'
```

### 多模态（图片输入）

Claude / GPT 视觉模型经 `/v1/chat/completions` 传图：

```bash
curl https://<cloudfront-domain>/v1/chat/completions \
  -H "Authorization: Bearer <master-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "opus-4-8",
    "messages": [{"role":"user","content":[
      {"type":"text","text":"这张图是什么？"},
      {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,<BASE64>"}}
    ]}]
  }'
```

> `drop_params: true` 只丢弃后端不支持的**参数**（如某模型不支持 temperature），不会删除消息里的 image content。多模态透传到 Bedrock Converse。

### Bedrock passthrough（原生 SDK）

```bash
curl https://<cloudfront-domain>/bedrock/model/us.anthropic.claude-opus-4-8/converse \
  -H "Authorization: Bearer <master-key>" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":[{"text":"hello"}]}]}'
```

---

## 排障

- `403 Direct access denied`：你直连了 ALB，请用 CloudFront 域名。
- `401`：master key 不对，检查 `Authorization: Bearer`。
- GPT 报 `does not support /v1/chat/completions`：该模型只支持 Responses API，用 `/v1/responses` 或 config 里已声明 `use_openai_responses_path`。
- 列出实际可用模型：`curl https://<cloudfront-domain>/v1/models -H "Authorization: Bearer <master-key>"`。
