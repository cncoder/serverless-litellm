# LiteLLM on EKS — 基于 Bedrock 的企业级 AI 网关

一键在 AWS 上部署 LiteLLM 代理，让团队通过统一 API Key 使用 Bedrock Claude 全系列模型。开箱即用对接 Claude Code 和 OpenClaw。

## 为什么需要 LiteLLM？

Bedrock 已经提供了无服务器推理、跨 Region 负载均衡和 IAM 鉴权。但企业多团队使用时，还需要：

- **per-user API Key** — 每人独立配额，离职即撤销，不暴露 AWS 凭证
- **实时用量仪表盘** — 按人 / 团队 / 模型维度拆账，不用等月底 CUR
- **自动 Fallback** — Opus 超时切 Sonnet 切 Haiku，跨模型容灾
- **双 API 格式** — OpenAI + Anthropic 格式同时支持，Claude Code / Cursor / OpenClaw 零改造接入
- **per-key 限速限额** — 防止单人打爆 Bedrock 配额

Bedrock 管模型和推理，LiteLLM 管人和成本。

## 架构

```
                    ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
                    │ Claude Code │  │  OpenClaw    │  │  自研应用   │
                    └──────┬──────┘  └──────┬──────┘  └──────┬──────┘
                           │                │                │
                           └────────────────┼────────────────┘
                                            │
                                   ┌────────▼────────┐
                                   │   ALB (HTTPS)   │
                                   │  + WAF 可选     │
                                   └───────┬─────────┘
                                           │
                              ┌────────────┼────────────┐
                              │                         │
                     ┌────────▼────────┐       ┌───────▼────────┐
                     │  /v1/* API 请求  │       │  /ui Admin UI  │
                     │  (API Key 认证)  │       │ (Cognito 认证) │
                     └────────┬────────┘       └───────┬────────┘
                              │                        │
                     ┌────────▼────────────────────────▼────────┐
                     │         LiteLLM Pods (2-10 replicas)     │
                     │              EKS Fargate                 │
                     │          IRSA — 零静态凭证                │
                     └──────┬──────────────────┬────────────────┘
                            │                  │
                   ┌────────▼────────┐  ┌──────▼───────┐
                   │  Amazon Bedrock │  │     RDS      │
                   │  Claude 全系列   │  │  PostgreSQL  │
                   │                 │  │  Key / 用量   │
                   │  us-west-2      │  └──────────────┘
                   │  us-east-1      │
                   │  (跨 Region)    │
                   └─────────────────┘
```

## 特性

- **Bedrock Claude 全系列** — Opus 4.6/4.5, Sonnet 4.6/4.5/3.7/3.5, Haiku 4.5，通配符路由 `bedrock/*`
- **完整降级链** — 自动 Fallback，3 次失败后切换备用模型
- **零静态凭证** — EKS IRSA（IAM Roles for Service Accounts），无需管理 AWS Access Key
- **Serverless 计算** — EKS Fargate，按需付费无需管理节点
- **RDS PostgreSQL** — API Key 管理 + Admin UI + 使用量统计
- **可选安全增强** — WAF 速率限制 + Cognito 用户认证（Admin UI / Dashboard 等非 API 接口通过 Cognito 登录保护，API 接口走 API Key 认证，两套鉴权互不干扰）

## 前置条件

- AWS CLI v2（已配置凭证）
- Terraform >= 1.5
- kubectl、Helm 3、envsubst（`gettext` 包）
- 域名 + ACM 证书（可选，无域名时使用 ALB DNS 直连）

## 快速开始

```bash
git clone https://github.com/cncoder/serverless-litellm.git
cd serverless-litellm

# 交互式一键部署（约 15-20 分钟）
./scripts/setup.sh
```

脚本完成后会输出：
- LiteLLM 地址（`https://litellm.example.com` 或 ALB DNS）
- Master Key（存储在 AWS Secrets Manager）

## 创建 API Key

部署完成后，通过 LiteLLM Admin UI 管理 API Key：

1. 访问 `https://<your-domain>/ui`
2. 使用 Master Key 登录
3. 在 Keys 页面创建、查看、删除 API Key

## 配置 Claude Code

两行命令即可让 Claude Code 通过 LiteLLM 走 Bedrock：

```bash
export ANTHROPIC_BASE_URL="https://<your-domain>"
export ANTHROPIC_API_KEY="<your-litellm-key>"

claude
```

> ⚠️ `ANTHROPIC_BASE_URL` 不要加 `/v1` 后缀 — Claude Code 会自动拼接 `/v1/messages`

切换模型：

```bash
claude --model claude-opus-4-6       # Opus 最强推理
claude --model claude-sonnet-4-6     # Sonnet 均衡（默认）
claude --model claude-haiku-4-5      # Haiku 快速响应
```

> 详细说明见 [docs/claude-code.md](docs/claude-code.md)

## 配置 OpenClaw

[OpenClaw](https://github.com/openclaw/openclaw) 是开源 AI 助手框架，支持 Discord/Telegram/Slack 等平台。通过 LiteLLM 接入 Bedrock：

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

> 详细说明见 [docs/openclaw.md](docs/openclaw.md)

## 文档

| 文档 | 说明 |
|------|------|
| [docs/openclaw.md](docs/openclaw.md) | OpenClaw AI 助手框架集成（中文） |
| [docs/claude-code.md](docs/claude-code.md) | Claude Code 配置、1M context、模型选择 |
| [docs/API_USAGE.md](docs/API_USAGE.md) | OpenAI SDK / Anthropic SDK / cURL 调用示例 |
| [docs/models.md](docs/models.md) | 可用模型列表、Fallback 链、路由策略 |
| [docs/manual-deploy.md](docs/manual-deploy.md) | 手动部署步骤（Terraform 变量、两阶段 ACM） |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 常见问题、调试命令、清理资源 |
| [docs/e2e-test-report.md](docs/e2e-test-report.md) | 端到端测试报告（14 项全通过） |

## 目录结构

```
.
├── terraform/          # 基础设施（EKS, VPC, RDS, ECR, WAF）
├── kubernetes/         # K8s 资源（Deployment, Service, Ingress, HPA）
├── scripts/
│   ├── setup.sh                # 一键部署
│   └── setup-claude-code.sh    # Claude Code 配置
└── docs/               # 详细文档
```

## License

MIT
