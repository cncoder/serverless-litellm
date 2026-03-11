# LiteLLM on EKS — Enterprise AI Gateway on Bedrock

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) [![AWS](https://img.shields.io/badge/AWS-EKS%20%2B%20Bedrock-orange)](docs/architecture.md)

[🇨🇳 中文版](README.md)

Deploy LiteLLM proxy on AWS with one command. Give your team unified API Keys to access Bedrock Claude models.

```
Bedrock handles models & inference → LiteLLM handles people & cost → CloudFront handles security
```

**Core capabilities**: Per-user API Keys · Real-time usage tracking · Auto fallback · OpenAI + Anthropic dual format · Per-key rate limits

## Architecture

<p align="center">
  <img src="docs/architecture.svg" alt="Architecture" width="100%"/>
</p>

## Features

- **Full Bedrock Claude lineup** — Opus 4.6/4.5/4.1, Sonnet 4.6/4.5/3.7/3.5, Haiku 4.5, wildcard routing `bedrock/*`
- **Complete fallback chain** — Auto-switch to backup model after 3 failures
- **Zero static credentials** — EKS IRSA (IAM Roles for Service Accounts)
- **Serverless compute** — EKS Fargate, pay-per-use with no node management
- **Prompt Caching** — Bedrock native support, auto-effective with Claude Code, ~90% input cost savings
- **RDS PostgreSQL** — API Key management + Admin UI + usage tracking
- **Optional security hardening** — WAF rate limiting + Cognito user auth

## Quick Start

```bash
git clone https://github.com/cncoder/serverless-litellm.git
cd serverless-litellm

# Interactive one-click deploy (~15-20 min)
./scripts/setup.sh
```

### Prerequisites

AWS CLI v2 · Terraform ≥ 1.5 · kubectl · Helm 3 · envsubst

## Configure Claude Code

Write to `~/.claude/settings.json` — **replace 2 values**:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://<your-domain>",
    "ANTHROPIC_API_KEY": "<your-litellm-key>"
  },
  "model": "claude-sonnet-4-6",
  "smallFastModel": "claude-haiku-4-5"
}
```

Verify: `claude --print "hello"`

Switch models: `claude --model claude-opus-4-6` / `claude --model opus` / `claude --model claude-opus-4-1`

> Full guide (templates, migration, caching, troubleshooting) → [docs/claude-code.md](docs/claude-code.md)

## Configure OpenClaw

> [OpenClaw](https://github.com/openclaw/openclaw) integration → [docs/openclaw.md](docs/openclaw.md)

## Documentation

| Document | Description |
|----------|-------------|
| ⭐ [Claude Code Setup](docs/claude-code.md) | settings.json templates, model selection, migration |
| ⭐ [Architecture](docs/architecture.md) | EKS, IRSA, Fargate, networking |
| [Available Models](docs/models.md) | Model list, fallback chains, routing |
| [API Examples](docs/API_USAGE.md) | OpenAI SDK / Anthropic SDK / cURL |
| [Manual Deploy](docs/manual-deploy.md) | Terraform variables, two-stage ACM |
| [Troubleshooting](docs/troubleshooting.md) | Real production experience |
| [Testing Guide](docs/testing-guide.md) | Functional / performance / HA / security |
| [Bedrock Monitoring](docs/bedrock-monitoring-guide.md) | Usage monitoring & cost analysis |

## CloudFront + WAF Hardening

Three-layer protection after deployment (ALB SG → WAF Header → path whitelist). See [skills/cloudfront-waf-hardening/SKILL.md](skills/cloudfront-waf-hardening/SKILL.md).

## Timeout Configuration

| Component | Value | Notes |
|-----------|-------|-------|
| CloudFront OriginReadTimeout | 60s | First-byte limit; streaming is NOT limited |
| ALB Idle Timeout | 600s | Connection drops if idle beyond this |
| LiteLLM request_timeout | 600s | Proxy-level timeout |
| K8s Ingress idle_timeout | 600s | ALB Ingress annotation |

> Claude Code uses streaming by default — not affected by CloudFront's 60s first-byte limit.

## Directory Structure

```
├── terraform/       # Infrastructure (EKS, VPC, RDS, ECR, WAF)
├── kubernetes/      # K8s resources (Deployment, Service, Ingress, HPA)
├── scripts/         # One-click deploy + Claude Code setup
├── skills/          # Claude Code Skills
└── docs/            # Documentation
```

## License

MIT

## References

- [Claude Code Quickstart](https://code.claude.com/docs/en/quickstart)
- [Claude Code LLM Gateway](https://code.claude.com/docs/en/llm-gateway)
- [Anthropic Prompt Caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
- [AWS Bedrock Prompt Caching](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html)
- [AWS Bedrock Claude Model Parameters](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-anthropic-claude-messages.html)
- [AWS Bedrock Cross-Region Inference](https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference.html)
- [LiteLLM Bedrock Integration](https://docs.litellm.ai/docs/providers/bedrock)
- [LiteLLM + Claude API](https://docs.litellm.ai/docs/tutorials/claude_responses_api)
- [EKS Fargate](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html)
- [EKS IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
