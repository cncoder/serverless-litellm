# CLAUDE.md — LiteLLM on EKS 项目指南

## 项目概述

在 AWS EKS 上部署 LiteLLM 代理，让团队通过统一 API Key 使用 Bedrock Claude 模型。

```
用户 → Claude Code → CloudFront → ALB → LiteLLM (EKS Fargate) → AWS Bedrock
```

## 快速部署（一键）

```bash
./scripts/setup.sh
```

交互式引导，约 15-20 分钟完成。自动创建 EKS 集群、RDS、ALB、WAF 等。

### 前置条件

- AWS CLI v2（已配置凭证，需 `AdministratorAccess` 或等效权限）
- Terraform ≥ 1.5
- kubectl
- Helm 3
- envsubst（macOS: `brew install gettext`）

### 部署流程

1. `scripts/setup.sh` → Terraform 创建基础设施（VPC/EKS/RDS/ECR/WAF）
2. 自动构建 LiteLLM Docker 镜像推送到 ECR
3. 部署 K8s 资源（Deployment/Service/Ingress/HPA/ConfigMap）
4. 输出 CloudFront 域名 + API Key

## 目录结构

```
terraform/          Terraform IaC（EKS, VPC, RDS, ECR, WAF, IAM）
kubernetes/         K8s 清单（ConfigMap 含模型路由 + Deployment + Ingress）
  └── configmap.yaml   ← 模型列表、Fallback 链、别名（核心配置）
scripts/            部署脚本 + 测试脚本
docs/               文档（架构/模型/API/排障/监控）
skills/             Claude Code Skills（CloudFront WAF 加固）
```

## 核心配置文件

### `kubernetes/configmap.yaml`

LiteLLM 的所有行为都在这里：

- `model_list`: 模型路由表（~23 条，含别名和 Fallback）
- `litellm_settings.drop_params: true`: 自动丢弃 Bedrock 不支持的参数
- `general_settings.master_key`: API 主密钥

模型名支持多种格式：`claude-sonnet-4-6` / `sonnet` / `claude-sonnet-4-6-20250514` / `us.anthropic.claude-sonnet-4-6`

### `terraform/`

- `main.tf` → EKS 集群 + Fargate Profile
- `rds.tf` → PostgreSQL（API Key 管理 + 用量统计）
- `waf.tf` → WAF 速率限制
- `variables.tf` → 所有可配置项
- **`terraform.tfvars` 绝不提交**（已在 .gitignore）

## 常见开发任务

### 添加新模型

编辑 `kubernetes/configmap.yaml`，在 `model_list` 下新增：

```yaml
- model_name: "新模型短名"
  litellm_params:
    model: "bedrock/us.anthropic.模型ID"
    aws_region_name: "us-east-1"
```

然后 `kubectl apply -f kubernetes/configmap.yaml && kubectl rollout restart deployment litellm-deployment -n litellm`

### 更新文档

- 用户指南: `docs/claude-code.md`（CC 配置、排障、迁移）
- 模型列表: `docs/models.md`
- README: `README.md`（中文）/ `README.en.md`（英文），保持同步

### 测试

```bash
# API 级别测试（需要 CloudFront 域名 + API Key）
bash scripts/test-models.sh

# E2E 测试
bash scripts/e2e-test.sh
```

## 关键技术决策

- **`drop_params: true`** — LiteLLM 自动丢弃 Bedrock 不支持的参数（如 `eager_input_streaming`）
- **零静态凭证** — EKS IRSA（Pod 通过 ServiceAccount 获取 IAM Role）
- **model_list 而非 model_group_alias** — alias 不支持 Anthropic `/v1/messages` 端点
- **Fallback 链**: Opus 4.6 → 4.1 → 4.5 → Sonnet 4.6 → 4.5 → 3.7
- **CloudFront 挡前面** — ALB 不公开，SG 锁 CloudFront IP 前缀列表
- **日志**: 生产环境 `log_raw_request_response: false`

## 安全

- `terraform.tfvars` 包含真实 AWS 资源 ID，**绝不提交到 git**
- API Key 存在 Secrets Manager，通过环境变量注入 Pod
- ALB Security Group 仅允许 CloudFront 前缀列表
- WAF 提供速率限制 + 自定义 Header 验证

## 代码风格

- 文档默认中文，技术术语保留英文
- README 中英文必须同步
- Commit message 用英文，格式: `docs:` / `feat:` / `fix:` / `refactor:`
- ConfigMap 改动后必须 rollout restart
