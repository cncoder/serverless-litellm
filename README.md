# LiteLLM on EKS — 基于 Bedrock 的企业级 AI 网关

> 在 AWS EKS Fargate 上部署 LiteLLM 代理，充分利用 Amazon Bedrock 的服务能力，为企业提供统一、安全、可控的 AI 模型访问层

## 为什么基于 Bedrock？

Amazon Bedrock 本身已经是一个托管的模型服务平台，但在企业多团队使用场景下，仍需要一个**应用层网关**来补齐管控能力：

### Bedrock 已有的能力（本方案充分利用）

- **无服务器推理** — 按 token 付费，无需管理 GPU 实例
- **跨 Region 推理** — Cross-Region Inference Profile（`global.*` 前缀），自动路由到最优 Region，提升吞吐、降低延迟
- **IAM 原生鉴权** — 与 AWS 权限体系深度集成，无需管理第三方 API Key
- **多模型供应** — Claude 全系列 + Llama + Mistral + Titan 等，同一 API 接口调用
- **数据驻留** — 请求数据不出 AWS 账户，满足合规要求

### LiteLLM 网关补齐的能力

| Bedrock 原生 | + LiteLLM 网关 |
|-------------|----------------|
| IAM 粒度到 Role/Policy | **per-user API Key**，每人独立配额和用量追踪 |
| CloudWatch 指标 | **实时 Admin UI 仪表盘**，按人/团队/模型/项目维度拆账 |
| 无内置降级逻辑 | **自动 Fallback 链**（Opus → Sonnet → Haiku），跨模型容灾 |
| SDK 调用需 Bedrock 格式 | **OpenAI + Anthropic 双格式兼容**，Claude Code / Cursor / OpenClaw 零改造接入 |
| 无速率限制 per-user | **per-key 速率限制 + 预算上限**，防止单人打爆配额 |
| 每次调用需 AWS 凭证 | **统一 API Key**，开发者无需配置 AWS 环境，降低 onboarding 成本 |

**一句话：Bedrock 管模型和推理，LiteLLM 管人和成本。两者结合 = 企业级 AI 基础设施。**

## 典型企业场景

### 🏢 开发团队（10-100 人）
- 每位开发者分配独立 LiteLLM Key，设定月度 token 预算
- 统一走 Bedrock，无需每人申请 Anthropic 账号
- Claude Code + Cursor + 自研工具全部指向同一网关

### 🔒 安全合规
- 所有 AI 请求经过 VPC 内网关，不直连外部 API
- WAF 速率限制 + Cognito 身份认证（可选）
- 请求/响应日志存 RDS，可对接 SIEM 审计系统

### 💰 成本优化
- 智能路由：简单任务走 Haiku（$0.25/M tokens），复杂任务走 Opus（$15/M tokens）
- 自动降级：Opus 超时自动切 Sonnet，保证可用性的同时降低 P99 成本
- 实时仪表盘：按团队/项目/模型维度拆分账单

### 🔄 多模型策略
- 灰度升级：新版模型（如 Sonnet 4.5 → 4.6）先给 10% 流量验证效果，逐步全量切换
- 智能降级：Opus 超时/限流时自动切 Sonnet，保证可用性
- 多 Region 冗余：`global.*` Inference Profile 跨 Region 负载均衡，单 Region 故障自动切换

---

## 架构

```
开发者 / Claude Code / OpenClaw / 自研应用
                │
        ALB (HTTPS + WAF 可选)
                │
       ┌────────┴─────────┐
  LiteLLM Pods (2-10)   RDS PostgreSQL
  EKS Fargate            Key 管理 / 用量统计
       │
  ┌────┴────┐
Bedrock    Bedrock
us-west-2  us-east-1
(多 Region 冗余)
```

## 特性

- **Bedrock Claude 全系列** — Opus 4.6/4.5, Sonnet 4.6/4.5/3.7/3.5, Haiku 4.5，通配符路由 `bedrock/*`
- **完整降级链** — 自动 Fallback，3 次失败后切换备用模型
- **零静态凭证** — EKS IRSA（IAM Roles for Service Accounts），无需管理 AWS Access Key
- **Serverless 计算** — EKS Fargate，按需付费无需管理节点
- **RDS PostgreSQL** — API Key 管理 + Admin UI + 使用量统计
- **可选安全增强** — WAF 速率限制 + Cognito 用户认证

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
