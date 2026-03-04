# LiteLLM on EKS

> 在 AWS EKS Fargate 上部署 LiteLLM 代理，统一管理 Amazon Bedrock Claude 模型的访问

## 特性

- **Bedrock Claude 全系列** - Opus 4.6/4.5, Sonnet 4.6/4.5/3.7/3.5, Haiku 4.5，支持通配符路由 `bedrock/*`
- **完整降级链** - 自动 Fallback，3 次失败后切换备用模型
- **零静态凭证** - EKS IRSA（IAM Roles for Service Accounts），无需管理 AWS Access Key
- **Serverless 计算** - EKS Fargate，按需付费无需管理节点
- **RDS PostgreSQL** - API Key 管理 + Admin UI + 使用量统计，一站式存储
- **可选安全增强** - WAF 速率限制 + Cognito 用户认证

## 架构

```
Internet → ALB (HTTPS + TLS 1.3 + WAF optional)
                │
                ├── litellm.example.com
                │   ├── /v1/*        → API Key 认证
                │   └── /* (UI)      → Cognito 认证 (可选)
                │
                └── other hosts → 403 Forbidden
                        │
               ┌────────┴────────────────┐
          LiteLLM Pods (2-10)      RDS PostgreSQL
          EKS Fargate              API Keys/Admin UI/Stats
               │
        ┌──────┴──────┐
    Bedrock          Bedrock
    us-west-2        us-east-1
```

## 前置条件

- AWS CLI v2（已配置凭证）
- Terraform >= 1.5
- kubectl、Helm 3、envsubst（`gettext` 包）
- 域名 + ACM 证书

## 快速开始

```bash
git clone <repository-url>
cd serverless-litellm

# 交互式一键部署（约 15-20 分钟）
./scripts/setup.sh
```

脚本完成后会输出：
- LiteLLM 地址（`https://litellm.example.com`）
- Master Key（存储在 AWS Secrets Manager）

## 创建 API Key

部署完成后，通过 LiteLLM Admin UI 管理 API Key：

1. 访问 `https://<YOUR_LITELLM_DOMAIN>/ui`
2. 使用 Master Key 登录
3. 在 Keys 页面创建、查看、删除 API Key

## 配置 Claude Code

两行命令即可让 Claude Code 通过 LiteLLM 走 Bedrock，无需 Anthropic API Key：

```bash
export ANTHROPIC_BASE_URL="https://<YOUR_LITELLM_DOMAIN>"
export ANTHROPIC_API_KEY="<YOUR_LITELLM_KEY>"

claude
```

或持久化写入 `~/.claude.json`：

```json
{
  "primaryProvider": "anthropic",
  "anthropicApiKey": "<YOUR_LITELLM_KEY>",
  "anthropicBaseUrl": "https://<YOUR_LITELLM_DOMAIN>"
}
```

切换模型：

```bash
claude --model claude-opus-4-6-us    # Opus 最强
claude --model claude-sonnet-4-6     # Sonnet 默认
claude --model claude-haiku-4-5      # Haiku 快速
```

> 详细说明见 [docs/claude-code.md](docs/claude-code.md)

## 文档

| 文档 | 说明 |
|------|------|
| [docs/manual-deploy.md](docs/manual-deploy.md) | 手动部署步骤（Terraform 变量、两阶段 ACM 部署） |
| [docs/models.md](docs/models.md) | 可用模型列表、Fallback 链、路由策略 |
| [docs/claude-code.md](docs/claude-code.md) | Claude Code 配置、1M context、模型选择 |
| [docs/API_USAGE.md](docs/API_USAGE.md) | OpenAI SDK / Anthropic SDK / cURL 调用示例 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 常见问题、调试命令、清理资源 |

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
