# LiteLLM on EKS — Enterprise AI Gateway on Bedrock

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) [![AWS](https://img.shields.io/badge/AWS-EKS%20%2B%20Bedrock-orange)](docs/architecture.md)

[🇨🇳 中文版](README.md)

Deploy LiteLLM proxy on AWS with one command. Give your team unified API Keys to access Bedrock Claude models.

```
Bedrock handles models & inference → LiteLLM handles people & cost → CloudFront handles security
```

## Why You Need This

| Pain Point | Solution |
|------------|----------|
| Every developer needs AWS credentials | Unified API Keys — per-user, per-user billing |
| No control over model usage and costs | Per-key rate limits + real-time usage dashboard |
| Want Claude Code but only have Bedrock | OpenAI + Anthropic dual format compatible |
| Occasional model errors disrupt work | Auto fallback — switches to backup after 3 failures |
| Want to save on Prompt Caching | Bedrock native support, ~90% input cost savings |

## Architecture

<p align="center">
  <img src="docs/architecture.svg" alt="Architecture" width="100%"/>
</p>

> Detailed architecture → [docs/architecture.md](docs/architecture.md)

## Quick Start

### Prerequisites

AWS CLI v2 · Terraform ≥ 1.5 · kubectl · Helm 3 · envsubst

### Deploy

```bash
git clone https://github.com/cncoder/serverless-litellm.git
cd serverless-litellm

# Interactive one-click deploy (~15-20 min)
./scripts/setup.sh
```

#### Configure Claude Code

**Install**:

```bash
# macOS / Linux / WSL (recommended)
curl -fsSL https://claude.ai/install.sh | bash

# npm
npm install -g @anthropic-ai/claude-code
```

**Configure** — write to `~/.claude/settings.json`, **replace 2 values**:

```jsonc
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://<your-domain>",   // ← replace
    "ANTHROPIC_API_KEY": "<your-litellm-key>"         // ← replace
  },
  "model": "claude-sonnet-4-6",
  "smallFastModel": "claude-haiku-4-5"
}
```

**Verify**: `claude --print "hello"`

Switch models: `claude --model claude-opus-4-6` / `claude --model opus` / `claude --model claude-opus-4-1`

> Full guide (optional params, migration, caching, troubleshooting) → [docs/claude-code.md](docs/claude-code.md)

## Documentation

| Document | Description |
|----------|-------------|
| ⭐ [Claude Code Setup](docs/claude-code.md) | settings.json templates, model selection, migration |
| ⭐ [Architecture](docs/architecture.md) | Networking, security, compute layer |
| [Available Models](docs/models.md) | Model list, fallback chains, routing |
| [API Examples](docs/API_USAGE.md) | OpenAI SDK / Anthropic SDK / cURL |
| [Manual Deploy](docs/manual-deploy.md) | Terraform variables, step-by-step deploy |
| [Troubleshooting](docs/troubleshooting.md) | Real production experience |
| [Bedrock Monitoring](docs/bedrock-monitoring-guide.md) | Usage monitoring & cost analysis |
| [Testing Guide](docs/testing-guide.md) | Functional / performance / HA / security |
| [OpenClaw Integration](docs/openclaw.md) | OpenClaw agent framework setup |

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
- [AWS Bedrock Prompt Caching](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html)
- [LiteLLM Bedrock Integration](https://docs.litellm.ai/docs/providers/bedrock)
- [AWS Bedrock Cross-Region Inference](https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference.html)
