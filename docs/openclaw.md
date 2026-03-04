# OpenClaw Configuration Guide

Use [OpenClaw](https://github.com/openclaw/openclaw) with LiteLLM as the AI backend, routing all requests through AWS Bedrock — no Anthropic API key required.

---

## What is OpenClaw?

OpenClaw is an open-source AI assistant framework that runs as a persistent daemon, connecting to messaging platforms (Discord, Telegram, Slack, etc.) and providing tool-use capabilities (file I/O, shell commands, browser automation, cron jobs, and more).

By default, OpenClaw connects directly to AI providers (Anthropic, OpenAI, etc.). With this LiteLLM integration, all AI requests route through your self-hosted LiteLLM proxy to AWS Bedrock — giving you:

- **No Anthropic API key needed** — use your existing AWS Bedrock access
- **Centralized usage tracking** — all token usage logged in LiteLLM's PostgreSQL database
- **Multi-model routing** — switch between Opus, Sonnet, Haiku via LiteLLM config
- **Automatic failover** — LiteLLM's fallback chains handle model unavailability
- **Cost control** — set per-key budgets and rate limits in LiteLLM Admin UI

---

## Prerequisites

- A running LiteLLM deployment (see [main README](../README.md))
- Your LiteLLM endpoint URL (e.g., `https://litellm.example.com`)
- A LiteLLM API key (Master Key or a key created via Admin UI)
- OpenClaw installed ([installation guide](https://docs.openclaw.ai))

---

## Quick Start

### 1. Install OpenClaw

```bash
# npm (Node.js 20+)
npm install -g openclaw

# Verify
openclaw --version
```

### 2. Initialize workspace

```bash
openclaw init
```

### 3. Configure LiteLLM as AI provider

Edit your OpenClaw config file (`~/.openclaw/openclaw.json`):

```json
{
  "ai": {
    "provider": "litellm",
    "model": "claude-sonnet-4-6",
    "baseUrl": "https://litellm.example.com",
    "apiKey": "sk-your-litellm-key"
  }
}
```

Or use environment variables:

```bash
export LITELLM_API_BASE="https://litellm.example.com"
export LITELLM_API_KEY="sk-your-litellm-key"
```

### 4. Start the gateway

```bash
openclaw gateway start
```

---

## Configuration Reference

### Minimal config (`openclaw.json`)

```json
{
  "ai": {
    "provider": "litellm",
    "model": "claude-sonnet-4-6",
    "baseUrl": "https://litellm.example.com",
    "apiKey": "sk-your-litellm-key"
  }
}
```

### Full config with model override and fallback

```json
{
  "ai": {
    "provider": "litellm",
    "model": "claude-sonnet-4-6",
    "baseUrl": "https://litellm.example.com",
    "apiKey": "sk-your-litellm-key"
  }
}
```

### Available models

Use any model alias defined in your LiteLLM config:

| Model | Best For | Cost |
|-------|----------|------|
| `claude-opus-4-6` | Complex reasoning, coding, analysis | $$$ |
| `claude-sonnet-4-6` | General tasks, balanced speed/quality | $$ |
| `claude-haiku-4-5` | Fast responses, simple tasks | $ |
| `claude-sonnet-4-5` | Previous generation Sonnet | $$ |

Switch models at runtime:

```bash
# Via OpenClaw CLI
openclaw config set ai.model claude-opus-4-6

# Or use /model command in chat
/model claude-opus-4-6
```

---

## How It Works

```
User (Discord/Telegram/CLI)
    │
    ▼
OpenClaw Gateway
    │
    ▼ (OpenAI-compatible API)
LiteLLM Proxy (https://litellm.example.com)
    │
    ├─ /v1/chat/completions  (streaming)
    ├─ /v1/models            (model listing)
    │
    ▼
AWS Bedrock (Claude models)
```

OpenClaw uses the OpenAI-compatible chat completions API (`/v1/chat/completions`), which LiteLLM natively supports. LiteLLM translates these requests to the appropriate Bedrock API format.

Key behaviors:
- **Streaming**: OpenClaw streams responses by default — LiteLLM handles SSE streaming correctly
- **Tool use**: OpenClaw's tool-calling features work through LiteLLM without modification
- **Token tracking**: All usage is logged by LiteLLM and visible in the Admin UI
- **Thinking/extended thinking**: Supported when using compatible models (Opus, Sonnet)

---

## Verify the Integration

### 1. Check LiteLLM health

```bash
curl -s https://litellm.example.com/health/liveliness
# Expected: "I'm alive!"
```

### 2. Test API connectivity

```bash
curl -s https://litellm.example.com/v1/chat/completions \
  -H "Authorization: Bearer sk-your-litellm-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-6",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 50
  }'
```

### 3. Test through OpenClaw

```bash
# Start gateway and send a test message
openclaw gateway start
# Send a message through your connected channel (Discord, Telegram, etc.)
# Or use the CLI: openclaw chat "Hello, world!"
```

### 4. Check token usage in LiteLLM

Visit `https://litellm.example.com/ui` → Login with Master Key → View usage dashboard.

---

## Deploy OpenClaw on EC2 with LiteLLM

For a complete cloud setup, deploy OpenClaw on an EC2 instance alongside your LiteLLM cluster:

```bash
# On an EC2 instance (Amazon Linux 2023 / Ubuntu 22.04)

# 1. Install Node.js
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh"
nvm install 22 && nvm use 22

# 2. Install OpenClaw
npm install -g openclaw

# 3. Initialize
openclaw init

# 4. Configure LiteLLM backend
cat > ~/.openclaw/openclaw.json << 'EOF'
{
  "ai": {
    "provider": "litellm",
    "model": "claude-sonnet-4-6",
    "baseUrl": "https://litellm.example.com",
    "apiKey": "sk-your-litellm-key"
  }
}
EOF

# 5. Start the gateway
openclaw gateway start
```

> **Tip**: If LiteLLM and OpenClaw are in the same VPC, use the internal ALB DNS
> (e.g., `http://internal-k8s-litellm-xxxx.us-west-2.elb.amazonaws.com`) for lower
> latency and no data transfer costs.

---

## Troubleshooting

### "Model not found" error

Ensure the model name in `openclaw.json` matches a model alias in your LiteLLM config:

```bash
# List available models
curl -s https://litellm.example.com/v1/models \
  -H "Authorization: Bearer sk-your-key" | jq '.data[].id' | head -20
```

### Connection timeout

- Verify LiteLLM is reachable: `curl -s https://litellm.example.com/health/liveliness`
- Check security groups allow traffic from OpenClaw's IP/VPC
- If using internal ALB, ensure OpenClaw EC2 is in the same VPC or has VPC peering

### Streaming issues

OpenClaw requires streaming support. Verify:

```bash
curl -N https://litellm.example.com/v1/chat/completions \
  -H "Authorization: Bearer sk-your-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"Hi"}],"max_tokens":10,"stream":true}'
```

You should see `data: {...}` chunks arriving incrementally.

### Token usage not appearing

- Check LiteLLM logs: `kubectl logs -n litellm -l app=litellm --tail 50`
- Ensure RDS is connected: usage data is stored in PostgreSQL
- Visit Admin UI → Usage tab

---

## Security Considerations

- **API Key rotation**: Create dedicated LiteLLM keys for each OpenClaw instance via Admin UI; revoke individually if compromised
- **Network isolation**: Place OpenClaw and LiteLLM in the same VPC; use internal ALB for API traffic
- **Budget limits**: Set per-key spending limits in LiteLLM to prevent runaway costs
- **Audit trail**: LiteLLM logs all requests with model, tokens, cost, and key metadata

---

## Related Documentation

- [OpenClaw Docs](https://docs.openclaw.ai) — Full OpenClaw documentation
- [OpenClaw GitHub](https://github.com/openclaw/openclaw) — Source code
- [LiteLLM Docs](https://docs.litellm.ai) — LiteLLM proxy documentation
- [Claude Code Guide](claude-code.md) — Configure Claude Code with LiteLLM
- [API Usage](API_USAGE.md) — Direct API call examples (OpenAI SDK, Anthropic SDK, cURL)
