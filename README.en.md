# LiteLLM on EKS — Enterprise AI Gateway on Bedrock

[🇨🇳 中文版](README.md)

Deploy LiteLLM proxy on AWS with one command. Give your team unified API Keys to access Bedrock Claude models. Works out-of-the-box with Claude Code and OpenClaw.

## Why LiteLLM?

Bedrock already provides serverless inference, cross-region load balancing, and IAM auth. But for multi-team enterprise use, you also need:

- **Per-user API Keys** — Individual quotas, instant revocation, no AWS credentials exposed
- **Real-time usage dashboard** — Track spend by user / team / model without waiting for monthly CUR
- **Auto fallback** — Opus timeout → Sonnet → Haiku, cross-model resilience
- **Dual API format** — OpenAI + Anthropic formats simultaneously; Claude Code / Cursor / OpenClaw work without modification
- **Per-key rate limits** — Prevent a single user from exhausting Bedrock quotas

Bedrock handles models and inference. LiteLLM handles people and cost.

## Architecture

<p align="center">
  <img src="docs/architecture.svg" alt="Architecture" width="100%"/>
</p>

## Features

- **Full Bedrock Claude lineup** — Opus 4.6/4.5, Sonnet 4.6/4.5/3.7/3.5, Haiku 4.5, wildcard routing `bedrock/*`
- **Complete fallback chain** — Auto-switch to backup model after 3 failures
- **Zero static credentials** — EKS IRSA (IAM Roles for Service Accounts)
- **Serverless compute** — EKS Fargate, pay-per-use with no node management
- **RDS PostgreSQL** — API Key management + Admin UI + usage tracking
- **Optional security hardening** — WAF rate limiting + Cognito user auth (Admin UI/Dashboard protected by Cognito login; API endpoints use API Key auth; two auth systems don't interfere)

## Prerequisites

- AWS CLI v2 (configured)
- Terraform >= 1.5
- kubectl, Helm 3, envsubst (`gettext` package)
- Domain + ACM certificate (optional; ALB DNS works without a domain)

## Quick Start

```bash
git clone https://github.com/cncoder/serverless-litellm.git
cd serverless-litellm

# Interactive one-click deploy (~15-20 min)
./scripts/setup.sh
```

After completion, the script outputs:
- LiteLLM endpoint (`https://litellm.example.com` or ALB DNS)
- Master Key (stored in AWS Secrets Manager)

## Create API Keys

Manage API Keys through the LiteLLM Admin UI:

1. Navigate to `https://<your-domain>/ui`
2. Log in with Master Key
3. Create, view, or revoke keys on the Keys page

## Configure Claude Code

Two commands to route Claude Code through LiteLLM → Bedrock:

```bash
export ANTHROPIC_BASE_URL="https://<your-domain>"
export ANTHROPIC_API_KEY="<your-litellm-key>"

claude
```

> ⚠️ `ANTHROPIC_BASE_URL` must NOT include the `/v1` suffix — Claude Code appends `/v1/messages` automatically

Switch models:

```bash
claude --model claude-opus-4-6       # Opus — strongest reasoning
claude --model claude-sonnet-4-6     # Sonnet — balanced (default)
claude --model claude-haiku-4-5      # Haiku — fastest
```

> See [docs/claude-code.md](docs/claude-code.md) for details

## Configure OpenClaw

[OpenClaw](https://github.com/openclaw/openclaw) is an open-source AI assistant framework supporting Discord/Telegram/Slack. Connect to Bedrock via LiteLLM:

```json
{
  "models": {
    "providers": {
      "litellm": {
        "baseUrl": "https://<your-domain>/v1",
        "apiKey": "<your-litellm-key>",
        "api": "openai-completions",
        "models": [
          { "id": "claude-sonnet-4-6", "name": "Claude Sonnet 4.6", "contextWindow": 200000, "maxTokens": 16384 }
        ]
      }
    }
  },
  "agents": { "defaults": { "model": "litellm/claude-sonnet-4-6" } },
  "gateway": { "mode": "local" }
}
```

> See [docs/openclaw.md](docs/openclaw.md) for details

## Documentation

| Document | Description |
|----------|-------------|
| [docs/architecture.md](docs/architecture.md) | Architecture deep-dive (EKS, IRSA, Fargate, networking) |
| [docs/openclaw.md](docs/openclaw.md) | OpenClaw integration + Amazon DCV remote desktop |
| [docs/claude-code.md](docs/claude-code.md) | Claude Code setup, 1M context, model selection |
| [docs/API_USAGE.md](docs/API_USAGE.md) | OpenAI SDK / Anthropic SDK / cURL examples |
| [docs/models.md](docs/models.md) | Available models, fallback chains, routing |
| [docs/bedrock-monitoring-guide.md](docs/bedrock-monitoring-guide.md) | Bedrock usage monitoring & cost analysis |
| [docs/manual-deploy.md](docs/manual-deploy.md) | Manual deployment (Terraform vars, two-stage ACM) |
| [docs/testing-guide.md](docs/testing-guide.md) | Full test guide (functional / performance / HA / security) |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Troubleshooting handbook (real production experience) |
| [docs/e2e-test-report.md](docs/e2e-test-report.md) | E2E test report (14/14 passed) |

## CloudFront + WAF Hardening

After deployment, harden your ALB with CloudFront + WAF for three layers of protection:

1. **ALB Security Group** — Only allow CloudFront IP ranges
2. **WAF Header Verification** — Block direct requests that bypass CloudFront
3. **WAF Path Whitelist** — Expose only API paths, block Admin UI and management endpoints

See [skills/cloudfront-waf-hardening/SKILL.md](skills/cloudfront-waf-hardening/SKILL.md) for step-by-step instructions, path whitelist templates, and rollback procedures.

## Directory Structure

```
.
├── terraform/          # Infrastructure (EKS, VPC, RDS, ECR, WAF)
├── kubernetes/         # K8s resources (Deployment, Service, Ingress, HPA)
├── scripts/
│   ├── setup.sh                # One-click deploy
│   └── setup-claude-code.sh    # Claude Code setup
├── skills/             # Claude Code Skills (reusable runbooks)
└── docs/               # Documentation
```

## Timeout & LLM Call Limits

LLM inference (especially Opus) can take significant time. All component timeouts are pre-configured and aligned:

| Component | Default | This Project | Notes |
|-----------|---------|-------------|-------|
| CloudFront OriginReadTimeout | 30s | 60s (max default) | First byte must arrive within 60s; **Streaming (SSE) is NOT limited** — once the first byte arrives, the stream continues indefinitely |
| ALB Idle Timeout | 60s | 600s | Connection drops if idle beyond this |
| LiteLLM request_timeout | 600s | 600s | Proxy-level request timeout |
| LiteLLM model timeout | 600s | 600s | Per-model call timeout; triggers fallback on expiry |
| K8s Ingress idle_timeout | 60s | 600s | ALB Ingress annotation |

**Common Issues:**

- **Claude Code interrupted during long reasoning?** — Claude Code uses Streaming by default. The CloudFront 60s limit only applies to the first byte. If the first byte exceeds 60s (extremely rare), request an OriginReadTimeout increase from AWS Support
- **504 on non-streaming requests?** — Non-streaming calls (e.g., `/v1/completions` without `stream:true`) are subject to CloudFront's 60s first-byte limit. Complex Opus reasoning may timeout. Always use `stream: true`
- **Fallback triggered too early?** — Check `timeout` and `num_retries` in `configmap.yaml`. Default: switch to backup model after 3 failures
- **Connection dropped while idle?** — ALB idle timeout is 600s. Connections with no data for 10 minutes will be terminated. Normal streaming scenarios won't trigger this

> To adjust timeouts: modify `kubernetes/configmap.yaml` (LiteLLM) and `kubernetes/ingress.yaml` (ALB). CloudFront timeouts require AWS Console or CLI changes.

## License

MIT
