# LiteLLM on EKS — 基于 Bedrock 的企业级 AI 网关

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) [![AWS](https://img.shields.io/badge/AWS-EKS%20%2B%20Bedrock-orange)](docs/architecture.md)

[🇺🇸 English](README.en.md)

一键在 AWS 上部署 LiteLLM 代理，让团队通过统一 API Key 使用 Bedrock Claude 全系列模型。

```
Bedrock 管模型和推理 → LiteLLM 管人和成本 → CloudFront 管安全
```

**核心能力**：per-user API Key · 实时用量拆账 · 自动 Fallback · OpenAI + Anthropic 双格式 · per-key 限速限额

## 架构

<p align="center">
  <img src="docs/architecture.svg" alt="Architecture" width="100%"/>
</p>

## 特性

- **Bedrock Claude 全系列** — Opus 4.6/4.5/4.1, Sonnet 4.6/4.5/3.7/3.5, Haiku 4.5，通配符路由 `bedrock/*`
- **完整降级链** — 自动 Fallback，3 次失败后切换备用模型
- **零静态凭证** — EKS IRSA（IAM Roles for Service Accounts），无需管理 AWS Access Key
- **Serverless 计算** — EKS Fargate，按需付费无需管理节点
- **Prompt Caching** — Bedrock 原生支持，Claude Code 自动生效，~90% input 成本节省
- **RDS PostgreSQL** — API Key 管理 + Admin UI + 使用量统计
- **可选安全增强** — WAF 速率限制 + Cognito 用户认证

## 快速开始

```bash
git clone https://github.com/cncoder/serverless-litellm.git
cd serverless-litellm

# 交互式一键部署（约 15-20 分钟）
./scripts/setup.sh
```

### 前置条件

AWS CLI v2 · Terraform ≥ 1.5 · kubectl · Helm 3 · envsubst

## 配置 Claude Code

将以下内容写入 `~/.claude/settings.json`，**只需替换 2 个值**：

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

验证：`claude --print "hello"`

切换模型：`claude --model claude-opus-4-6` / `claude --model opus` / `claude --model claude-opus-4-1`

> 详细配置（完整模板、迁移指南、Prompt Caching、Troubleshooting）→ [docs/claude-code.md](docs/claude-code.md)

## 配置 OpenClaw

> [OpenClaw](https://github.com/openclaw/openclaw) 集成详见 [docs/openclaw.md](docs/openclaw.md)

## 文档

| 文档 | 说明 |
|------|------|
| ⭐ [Claude Code 配置](docs/claude-code.md) | settings.json 模板、模型选择、迁移指南 |
| ⭐ [架构设计](docs/architecture.md) | EKS, IRSA, Fargate, 网络拓扑 |
| [可用模型](docs/models.md) | 模型列表、Fallback 链、路由策略 |
| [API 调用示例](docs/API_USAGE.md) | OpenAI SDK / Anthropic SDK / cURL |
| [手动部署](docs/manual-deploy.md) | Terraform 变量、两阶段 ACM |
| [故障排查](docs/troubleshooting.md) | 真实生产环境经验 |
| [测试指南](docs/testing-guide.md) | 功能 / 性能 / HA / 安全 |
| [Bedrock 监控](docs/bedrock-monitoring-guide.md) | 用量监控与成本分析 |

## CloudFront + WAF 加固

部署后建议通过 CloudFront + WAF 实现三层防护（ALB SG → WAF Header → 路径白名单）。详见 [skills/cloudfront-waf-hardening/SKILL.md](skills/cloudfront-waf-hardening/SKILL.md)。

## 超时配置

| 组件 | 配置值 | 说明 |
|------|--------|------|
| CloudFront OriginReadTimeout | 60s | 首字节限制；Streaming 不受此限 |
| ALB Idle Timeout | 600s | 连接空闲断开时间 |
| LiteLLM request_timeout | 600s | 代理层超时 |
| K8s Ingress idle_timeout | 600s | ALB Ingress 注解 |

> Claude Code 默认走 Streaming，不受 CloudFront 60s 首字节限制。

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
- [Anthropic Prompt Caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
- [AWS Bedrock Prompt Caching](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html)
- [AWS Bedrock Claude 模型参数](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-anthropic-claude-messages.html)
- [AWS Bedrock Cross-Region Inference](https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference.html)
- [LiteLLM Bedrock 集成](https://docs.litellm.ai/docs/providers/bedrock)
- [LiteLLM + Claude API](https://docs.litellm.ai/docs/tutorials/claude_responses_api)
- [EKS Fargate 文档](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html)
- [EKS IRSA 文档](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
