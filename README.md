# LiteLLM on EKS — 基于 Bedrock 的企业级 AI 网关

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) [![AWS](https://img.shields.io/badge/AWS-EKS%20%2B%20Bedrock-orange)](docs/architecture.md)

[🇺🇸 English](README.en.md)

一键在 AWS 上部署 LiteLLM 代理，让团队通过统一 API Key 使用 Bedrock Claude 全系列模型。

```
Bedrock 管模型和推理 → LiteLLM 管人和成本 → CloudFront 管安全
```

## 为什么需要它

| 痛点 | 方案 |
|------|------|
| 每个开发者都要配 AWS 凭证 | 统一 API Key，按人分配、按人计费 |
| 无法控制模型用量和成本 | per-key 限速限额 + 实时用量看板 |
| 想用 Claude Code 但只有 Bedrock | OpenAI + Anthropic 双格式兼容 |
| 模型偶尔报错影响开发 | 自动 Fallback，3 次失败切备用模型 |
| Prompt Caching 想省钱 | Bedrock 原生支持，~90% input 成本节省 |

## 架构

<p align="center">
  <img src="docs/architecture.svg" alt="Architecture" width="100%"/>
</p>

> 详细架构说明 → [docs/architecture.md](docs/architecture.md)

## 快速开始

### 前置条件

AWS CLI v2 · Terraform ≥ 1.5 · kubectl · Helm 3 · envsubst

### 部署

```bash
git clone https://github.com/cncoder/serverless-litellm.git
cd serverless-litellm

# 交互式一键部署（约 15-20 分钟）
./scripts/setup.sh
```

### 配置 Claude Code

**安装**：

```bash
# macOS / Linux / WSL（推荐）
curl -fsSL https://claude.ai/install.sh | bash

# npm
npm install -g @anthropic-ai/claude-code
```

**配置** — 写入 `~/.claude/settings.json`，**只需替换 2 个值**：

```jsonc
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://<your-domain>",   // ← 替换
    "ANTHROPIC_API_KEY": "<your-litellm-key>",        // ← 替换
    "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1",
    "DISABLE_BUG_COMMAND": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  },
  "model": "claude-sonnet-4-6",
  "smallFastModel": "claude-haiku-4-5"
}
```

**验证**：`claude --print "hello"`

切换模型：`claude --model claude-opus-4-6` / `claude --model opus` / `claude --model claude-opus-4-1`

> 详细配置（可选参数、迁移指南、Prompt Caching、Troubleshooting）→ [docs/claude-code.md](docs/claude-code.md)

## 文档

| 文档 | 说明 |
|------|------|
| ⭐ [Claude Code 配置](docs/claude-code.md) | settings.json 模板、模型选择、迁移指南 |
| ⭐ [架构设计](docs/architecture.md) | 网络拓扑、安全机制、计算层 |
| [可用模型](docs/models.md) | 模型列表、Fallback 链、路由策略 |
| [API 调用示例](docs/API_USAGE.md) | OpenAI SDK / Anthropic SDK / cURL |
| [手动部署](docs/manual-deploy.md) | Terraform 变量、分步部署 |
| [故障排查](docs/troubleshooting.md) | 真实生产环境经验 |
| [Bedrock 监控](docs/bedrock-monitoring-guide.md) | 用量监控与成本分析 |
| [测试指南](docs/testing-guide.md) | 功能 / 性能 / HA / 安全 |
| [OpenClaw 集成](docs/openclaw.md) | OpenClaw Agent 框架对接 |

## 目录结构

```
├── terraform/       # 基础设施（EKS, VPC, RDS, ECR, WAF）
├── kubernetes/      # K8s 资源（Deployment, Service, Ingress, HPA）
├── scripts/         # 一键部署 + Claude Code 配置
├── skills/          # Claude Code Skills
└── docs/            # 详细文档
```

## License

MIT

## 参考链接

- [Claude Code 快速开始](https://code.claude.com/docs/en/quickstart)
- [Claude Code LLM Gateway 配置](https://code.claude.com/docs/en/llm-gateway)
- [AWS Bedrock Prompt Caching](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html)
- [LiteLLM Bedrock 集成](https://docs.litellm.ai/docs/providers/bedrock)
- [AWS Bedrock Cross-Region Inference](https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference.html)
