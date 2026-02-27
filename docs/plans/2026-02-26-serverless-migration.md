# LiteLLM Serverless 迁移实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 LiteLLM on EKS 从 PostgreSQL+Redis+EC2 架构迁移到 DynamoDB+Fargate 轻量 Serverless 方案，支持 20 用户 2 Pod 部署，包含交互式部署脚本和端到端测试。

**Architecture:** EKS Fargate 模式运行 LiteLLM Pod，DynamoDB 存储用户 API key（通过 custom_auth.py），去掉 Aurora PostgreSQL 和 ElastiCache Redis，路由状态改用内存。VPC 简化为两层（public+private），WAF 和 Cognito 可选。交互式 shell 脚本引导用户选择 region、VPC（新建或导入）、可选组件后一键部署。

**Tech Stack:** Terraform, EKS Fargate, DynamoDB, ECR, Docker, Python (boto3), Bash

---

## Task 1: 创建 Dockerfile 和 custom_auth.py

**Files:**
- Create: `docker/Dockerfile`
- Create: `docker/custom_auth.py`
- Create: `docker/requirements-custom.txt`

**Step 1: 创建 docker 目录结构**

```bash
mkdir -p docker
```

**Step 2: 创建 custom_auth.py**

```python
"""
LiteLLM Custom Auth — DynamoDB 后端
从 DynamoDB 表查询 API key，支持用户级别的预算和模型权限控制。
"""
import os
import time
from typing import Optional, Union

import boto3
from botocore.exceptions import ClientError
from fastapi import Request
from litellm.proxy._types import UserAPIKeyAuth, ProxyException

# DynamoDB 配置
_REGION = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-west-2"))
_TABLE_NAME = os.environ.get("DYNAMODB_API_KEYS_TABLE", "litellm-api-keys")

# 简单内存缓存（减少 DynamoDB 读取）
_cache: dict = {}
_CACHE_TTL = int(os.environ.get("AUTH_CACHE_TTL_SECONDS", "60"))

dynamodb = boto3.resource("dynamodb", region_name=_REGION)
table = dynamodb.Table(_TABLE_NAME)


def _get_from_cache(api_key: str) -> Optional[dict]:
    entry = _cache.get(api_key)
    if entry and (time.time() - entry["ts"]) < _CACHE_TTL:
        return entry["item"]
    return None


def _put_to_cache(api_key: str, item: dict) -> None:
    _cache[api_key] = {"item": item, "ts": time.time()}


async def user_api_key_auth(
    request: Request, api_key: str
) -> Union[UserAPIKeyAuth, str]:
    """LiteLLM custom auth hook — 从 DynamoDB 验证 API key."""
    try:
        # 1. 检查内存缓存
        item = _get_from_cache(api_key)

        # 2. 缓存未命中则查 DynamoDB
        if item is None:
            resp = table.get_item(Key={"api_key": api_key})
            item = resp.get("Item")
            if item:
                _put_to_cache(api_key, item)

        # 3. key 不存在或已禁用
        if not item or not item.get("enabled", True):
            raise ProxyException(
                message="Invalid or disabled API key",
                type="auth_error",
                param="api_key",
                code=401,
            )

        # 4. 构建认证结果
        return UserAPIKeyAuth(
            api_key=api_key,
            user_id=item.get("user_id", "unknown"),
            max_budget=float(item["max_budget"]) if item.get("max_budget") else None,
        )

    except ProxyException:
        raise
    except ClientError as e:
        raise ProxyException(
            message=f"Auth service error: {e.response['Error']['Code']}",
            type="internal_error",
            param="api_key",
            code=500,
        )
    except Exception as e:
        raise ProxyException(
            message=f"Authentication failed: {str(e)}",
            type="auth_error",
            param="api_key",
            code=401,
        )
```

**Step 3: 创建 requirements-custom.txt**

```
boto3>=1.34.0
```

**Step 4: 创建 Dockerfile**

```dockerfile
FROM ghcr.io/berriai/litellm:main-stable

# 安装 DynamoDB 认证依赖
COPY requirements-custom.txt /tmp/requirements-custom.txt
RUN pip install --no-cache-dir -r /tmp/requirements-custom.txt && rm /tmp/requirements-custom.txt

# 复制自定义认证模块
COPY custom_auth.py /app/custom_auth.py

WORKDIR /app
```

**Step 5: Commit**

```bash
git add docker/
git commit -m "feat: add Dockerfile and DynamoDB custom auth"
```

---

## Task 2: 创建 DynamoDB Terraform 模块

**Files:**
- Create: `terraform/modules/dynamodb/main.tf`
- Create: `terraform/modules/dynamodb/variables.tf`
- Create: `terraform/modules/dynamodb/outputs.tf`

**Step 1: 创建 dynamodb 模块目录**

```bash
mkdir -p terraform/modules/dynamodb
```

**Step 2: 创建 main.tf**

```hcl
resource "aws_dynamodb_table" "api_keys" {
  name         = "${var.project_name}-${var.environment}-api-keys"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "api_key"

  attribute {
    name = "api_key"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-api-keys"
    Project     = var.project_name
    Environment = var.environment
  }
}
```

**Step 3: 创建 variables.tf**

```hcl
variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}
```

**Step 4: 创建 outputs.tf**

```hcl
output "table_name" {
  description = "DynamoDB API keys table name"
  value       = aws_dynamodb_table.api_keys.name
}

output "table_arn" {
  description = "DynamoDB API keys table ARN"
  value       = aws_dynamodb_table.api_keys.arn
}
```

**Step 5: Commit**

```bash
git add terraform/modules/dynamodb/
git commit -m "feat: add DynamoDB Terraform module for API key storage"
```

---

## Task 3: 创建 ECR Terraform 模块

**Files:**
- Create: `terraform/modules/ecr/main.tf`
- Create: `terraform/modules/ecr/variables.tf`
- Create: `terraform/modules/ecr/outputs.tf`

**Step 1: 创建 ecr 模块目录**

```bash
mkdir -p terraform/modules/ecr
```

**Step 2: 创建 main.tf**

```hcl
resource "aws_ecr_repository" "litellm" {
  name                 = "${var.project_name}-${var.environment}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_ecr_lifecycle_policy" "litellm" {
  repository = aws_ecr_repository.litellm.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
```

**Step 3: 创建 variables.tf**

```hcl
variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}
```

**Step 4: 创建 outputs.tf**

```hcl
output "repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.litellm.repository_url
}

output "repository_arn" {
  description = "ECR repository ARN"
  value       = aws_ecr_repository.litellm.arn
}
```

**Step 5: Commit**

```bash
git add terraform/modules/ecr/
git commit -m "feat: add ECR Terraform module"
```

---

## Task 4: 改造 VPC 模块（两层子网 + 支持导入）

**Files:**
- Modify: `terraform/modules/vpc/main.tf` — 删除 database 子网层
- Modify: `terraform/modules/vpc/outputs.tf` — 删除 database_subnet_ids
- Modify: `terraform/modules/vpc/variables.tf` — 无需改

**Step 1: 修改 main.tf，删除 database 相关资源**

删除以下资源块：
- `aws_subnet.database`
- `aws_route_table.database`
- `aws_route_table_association.database`

**Step 2: 修改 outputs.tf，删除 database_subnet_ids**

删除：
```hcl
output "database_subnet_ids" { ... }
```

**Step 3: Commit**

```bash
git add terraform/modules/vpc/
git commit -m "refactor: simplify VPC to two-tier (public + private), remove database subnets"
```

---

## Task 5: 改造 EKS 模块（Fargate 替代 Node Group）

**Files:**
- Modify: `terraform/modules/eks/main.tf` — 删除 Node Group，添加 Fargate Profile
- Modify: `terraform/modules/eks/variables.tf` — 删除 node_* 变量，添加 fargate 变量
- Modify: `terraform/modules/eks/outputs.tf` — 无需改

**Step 1: 修改 main.tf**

删除：
- `aws_eks_node_group.main` 整个资源块
- `aws_eks_addon.metrics_server`（Fargate 不需要）

修改 `aws_eks_addon.coredns`：
- 去掉 `depends_on = [aws_eks_node_group.main]`
- 改为 `depends_on = [aws_eks_fargate_profile.default]`
- 添加 `configuration_values` 让 coredns 跑在 Fargate 上

添加 Fargate Profile：
```hcl
resource "aws_eks_fargate_profile" "default" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "${var.cluster_name}-fargate-default"
  pod_execution_role_arn = var.fargate_pod_execution_role_arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = "litellm"
  }

  selector {
    namespace = "kube-system"
  }

  tags = {
    Name        = "${var.cluster_name}-fargate-default"
    Project     = var.project_name
    Environment = var.environment
  }
}
```

**Step 2: 修改 variables.tf**

删除：`node_role_arn`, `node_instance_type`, `node_desired_size`, `node_min_size`, `node_max_size`

添加：
```hcl
variable "fargate_pod_execution_role_arn" {
  description = "IAM role ARN for Fargate pod execution"
  type        = string
}
```

**Step 3: Commit**

```bash
git add terraform/modules/eks/
git commit -m "feat: replace EC2 Node Group with Fargate Profile"
```

---

## Task 6: 改造 IAM 模块（Fargate + DynamoDB 权限）

**Files:**
- Modify: `terraform/modules/iam/main.tf`
- Modify: `terraform/modules/iam/variables.tf`
- Modify: `terraform/modules/iam/outputs.tf`

**Step 1: 修改 main.tf**

删除：`aws_iam_role.eks_node` 和其所有 `aws_iam_role_policy_attachment`（3 个）

添加 Fargate Pod Execution Role：
```hcl
resource "aws_iam_role" "fargate_pod_execution" {
  name = "${var.project_name}-${var.environment}-fargate-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks-fargate-pods.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "fargate_pod_execution" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.fargate_pod_execution.name
}

resource "aws_iam_role_policy_attachment" "fargate_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.fargate_pod_execution.name
}
```

给 litellm_pod role 添加 DynamoDB 权限：
```hcl
resource "aws_iam_role_policy" "litellm_dynamodb" {
  name = "${var.project_name}-${var.environment}-litellm-dynamodb-policy"
  role = aws_iam_role.litellm_pod.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:BatchGetItem"
        ]
        Resource = var.dynamodb_table_arn
      }
    ]
  })
}
```

**Step 2: 修改 variables.tf**

添加：
```hcl
variable "dynamodb_table_arn" {
  description = "DynamoDB API keys table ARN"
  type        = string
}
```

**Step 3: 修改 outputs.tf**

替换 `eks_node_role_arn` 为：
```hcl
output "fargate_pod_execution_role_arn" {
  description = "ARN of the Fargate pod execution IAM role"
  value       = aws_iam_role.fargate_pod_execution.arn
}
```

**Step 4: Commit**

```bash
git add terraform/modules/iam/
git commit -m "feat: add Fargate execution role and DynamoDB permissions, remove node role"
```

---

## Task 7: 改造 ConfigMap（去掉 Redis，加 custom_auth）

**Files:**
- Modify: `kubernetes/configmap.yaml`

**Step 1: 修改 router_settings**

删除 Redis 相关配置（redis_host, redis_port, cache_kwargs, cache_responses, redis_max_connections）。

**Step 2: 修改 general_settings**

删除：`store_model_in_db`, `store_prompts_in_spend_logs`, `database_url`

添加：`custom_auth: custom_auth.user_api_key_auth`

**Step 3: Commit**

```bash
git add kubernetes/configmap.yaml
git commit -m "refactor: remove Redis/DB config, add DynamoDB custom auth"
```

---

## Task 8: 改造 K8s Deployment 和 Secret

**Files:**
- Modify: `kubernetes/deployment.yaml` — 改镜像为 ECR，加 DynamoDB 环境变量
- Modify: `kubernetes/secret.yaml.template` — 去掉 DB/Redis，加 DynamoDB 表名
- Modify: `kubernetes/hpa.yaml` — 去掉 metrics-server 依赖的 memory metric（Fargate 限制）

**Step 1: 修改 deployment.yaml**

- 镜像改为 `${ECR_REPOSITORY_URL}:latest`（模板变量，由 post-deploy 替换）
- 环境变量：去掉 DATABASE_URL, REDIS_HOST, REDIS_PORT, STORE_MODEL_IN_DB, STORE_PROMPTS_IN_SPEND_LOGS
- 添加环境变量：DYNAMODB_API_KEYS_TABLE, AWS_REGION
- Fargate 注意：去掉 `topologySpreadConstraints`（如果有）

**Step 2: 修改 secret.yaml.template**

去掉 DATABASE_URL, REDIS_HOST, REDIS_PORT。只保留 LITELLM_MASTER_KEY。

**Step 3: 修改 hpa.yaml**

Fargate 对 HPA 有限制。改为只用 CPU metric。maxReplicas 改为 4（20 用户够了）。

**Step 4: Commit**

```bash
git add kubernetes/deployment.yaml kubernetes/secret.yaml.template kubernetes/hpa.yaml
git commit -m "refactor: update K8s manifests for Fargate + DynamoDB"
```

---

## Task 9: 改造根模块 main.tf 和 variables.tf

**Files:**
- Modify: `terraform/main.tf` — 去掉 aurora/elasticache，加 dynamodb/ecr，改 EKS 参数
- Modify: `terraform/variables.tf` — 去掉 DB 变量，加 VPC 导入变量
- Modify: `terraform/outputs.tf` — 去掉 aurora/redis 输出

**Step 1: 修改 main.tf**

删除：
- `module "aurora"` 整个块
- `module "elasticache"` 整个块

添加：
```hcl
module "ecr" {
  source       = "./modules/ecr"
  project_name = var.project_name
  environment  = var.environment
}

module "dynamodb" {
  source       = "./modules/dynamodb"
  project_name = var.project_name
  environment  = var.environment
}
```

修改 `module "vpc"`：添加 `count = var.create_vpc ? 1 : 0` 支持导入已有 VPC

修改 `module "eks"`：
- 删除 `node_role_arn`, `node_instance_type`, `node_desired_size`, `node_min_size`, `node_max_size`
- 添加 `fargate_pod_execution_role_arn = module.iam.fargate_pod_execution_role_arn`

修改 `module "iam"`：添加 `dynamodb_table_arn = module.dynamodb.table_arn`

修改 `module "post_deploy"`：
- 删除 `aurora_*` 和 `redis_host` 参数
- 添加 `ecr_repository_url`, `dynamodb_table_name`
- depends_on 去掉 `module.aurora`, `module.elasticache`

**Step 2: 修改 variables.tf**

删除：`db_master_username`, `db_name`, `db_min_capacity`, `db_max_capacity`, `node_instance_type`, `node_desired_size`, `node_min_size`, `node_max_size`

添加 VPC 导入支持：
```hcl
variable "create_vpc" {
  description = "是否创建新 VPC（false 则使用已有 VPC）"
  type        = bool
  default     = true
}

variable "existing_vpc_id" {
  description = "已有 VPC ID（create_vpc=false 时使用）"
  type        = string
  default     = ""
}

variable "existing_public_subnet_ids" {
  description = "已有 public 子网 ID 列表"
  type        = list(string)
  default     = []
}

variable "existing_private_subnet_ids" {
  description = "已有 private 子网 ID 列表"
  type        = list(string)
  default     = []
}
```

添加 Cognito 可选：
```hcl
variable "enable_cognito" {
  description = "是否启用 Cognito UI 认证"
  type        = bool
  default     = false
}
```

**Step 3: 修改 outputs.tf**

删除：`aurora_endpoint`, `redis_endpoint`
添加：`dynamodb_table_name`, `ecr_repository_url`（如果还没有）

**Step 4: Commit**

```bash
git add terraform/main.tf terraform/variables.tf terraform/outputs.tf
git commit -m "refactor: rewire root module for serverless (Fargate + DynamoDB + ECR)"
```

---

## Task 10: 改造 post-deploy 模块

**Files:**
- Modify: `terraform/modules/post-deploy/main.tf`
- Modify: `terraform/modules/post-deploy/variables.tf`

**Step 1: 修改 main.tf**

- 删除 Aurora 密码获取逻辑（Secrets Manager 查询）
- 删除 DATABASE_URL 和 REDIS_HOST/PORT 的 Secret 创建
- 添加 ECR 镜像构建和推送步骤（docker build + push）
- Secret 只保留 LITELLM_MASTER_KEY，添加 DYNAMODB_API_KEYS_TABLE
- Ingress 模板替换添加 Cognito 可选逻辑

**Step 2: 修改 variables.tf**

删除：`aurora_endpoint`, `aurora_master_username`, `aurora_db_name`, `aurora_master_user_secret_arn`, `redis_host`

添加：`ecr_repository_url`, `dynamodb_table_name`, `enable_cognito`

**Step 3: Commit**

```bash
git add terraform/modules/post-deploy/
git commit -m "refactor: update post-deploy for serverless architecture"
```

---

## Task 11: 改造 Ingress（Cognito 可选）

**Files:**
- Modify: `kubernetes/ingress.yaml`

**Step 1: 将 Cognito ingress 拆为两个模板**

创建 `kubernetes/ingress-cognito.yaml`（带 Cognito 认证的 UI ingress）和修改 `kubernetes/ingress.yaml`（无 Cognito 的 UI ingress）。

或者在 post-deploy 里根据 `enable_cognito` 变量决定用 envsubst 替换哪个模板。

**Step 2: Commit**

```bash
git add kubernetes/
git commit -m "feat: make Cognito UI auth optional"
```

---

## Task 12: 创建交互式部署脚本 setup.sh

**Files:**
- Create: `scripts/setup.sh`

**Step 1: 创建引导式 shell 脚本**

脚本流程：
1. 欢迎信息和前置检查（terraform, aws, kubectl, docker）
2. 选择 AWS Region（列出常用 region + 自定义输入）
3. VPC 选择：
   - 新建 VPC（自动生成 CIDR 和子网）
   - 导入已有 VPC（列出当前 region 的 VPC → 用户选择 → 列出子网 → 用户选择 public/private 子网）
4. 可选组件：
   - 启用 WAF？(y/n)
   - 启用 Cognito UI 认证？(y/n)
   - 如果启用 Cognito，输入 User Pool ARN、Client ID、Domain
5. 域名配置：
   - LiteLLM host
   - Bot host（可选）
   - ACM 证书 ARN
6. 生成 terraform.tfvars
7. 确认后执行 terraform init + plan + apply
8. 构建 Docker 镜像并推送到 ECR
9. 创建初始管理员 API key 到 DynamoDB
10. 输出部署信息和下一步操作

**Step 2: 确保脚本可执行**

```bash
chmod +x scripts/setup.sh
```

**Step 3: Commit**

```bash
git add scripts/setup.sh
git commit -m "feat: add interactive setup script with region/VPC/component selection"
```

---

## Task 13: 创建用户管理脚本

**Files:**
- Create: `scripts/manage-keys.sh`

**Step 1: 创建 DynamoDB key 管理脚本**

功能：
- `./manage-keys.sh add <user_id> [--budget 100]` — 生成 API key 并写入 DynamoDB
- `./manage-keys.sh list` — 列出所有用户
- `./manage-keys.sh disable <api_key>` — 禁用 key
- `./manage-keys.sh enable <api_key>` — 启用 key
- `./manage-keys.sh delete <api_key>` — 删除 key

**Step 2: Commit**

```bash
git add scripts/manage-keys.sh
git commit -m "feat: add DynamoDB API key management script"
```

---

## Task 14: 更新 terraform.tfvars.example

**Files:**
- Modify: `terraform/terraform.tfvars.example`

**Step 1: 更新示例配置**

删除所有 Aurora/Redis/Node Group 相关配置。
添加 VPC 导入、Cognito 可选、WAF 可选的示例。

**Step 2: Commit**

```bash
git add terraform/terraform.tfvars.example
git commit -m "docs: update tfvars example for serverless architecture"
```

---

## Task 15: 删除废弃的 Terraform 模块

**Files:**
- Delete: `terraform/modules/aurora/` (整个目录)
- Delete: `terraform/modules/elasticache/` (整个目录)

**Step 1: 移除废弃模块**

```bash
mv terraform/modules/aurora ~/Documents/trashllm/aurora-module-backup
mv terraform/modules/elasticache ~/Documents/trashllm/elasticache-module-backup
```

**Step 2: Commit**

```bash
git add -A terraform/modules/aurora terraform/modules/elasticache
git commit -m "chore: remove Aurora and ElastiCache modules (replaced by DynamoDB)"
```

---

## Task 16: 端到端测试脚本

**Files:**
- Create: `scripts/e2e-test.sh`
- Modify: `scripts/test-models.sh` — 适配新架构
- Modify: `scripts/benchmark.sh` — 适配新架构

**Step 1: 创建 e2e-test.sh**

完整测试流程：
1. **基础健康检查**
   - `GET /health/liveliness` → 200
   - `GET /health/readiness` → 200

2. **认证测试**
   - 无 key 请求 → 401
   - 错误 key 请求 → 401
   - 禁用的 key 请求 → 401
   - 有效 key 请求 → 200

3. **模型可用性测试**
   - 遍历所有模型发送简单 prompt
   - 记录响应时间和状态

4. **Fallback 链测试**
   - 使用不存在的模型名触发 fallback
   - 验证降级到备用模型

5. **并发压力测试**
   - 使用 `ab` 或 `wrk` 进行并发请求
   - 20 并发 × 100 请求
   - 报告：成功率、P50/P90/P99 延迟、吞吐量

6. **DynamoDB 认证性能测试**
   - 100 次连续认证请求
   - 测量缓存命中 vs 未命中的延迟差异

7. **报告生成**
   - 输出结构化测试报告（通过/失败/跳过）
   - 记录到 `test-results/` 目录

**Step 2: 更新 test-models.sh**

更新 endpoint URL 和认证方式（使用 DynamoDB 中的 key）。

**Step 3: 更新 benchmark.sh**

更新认证方式，添加更多指标输出。

**Step 4: Commit**

```bash
git add scripts/
git commit -m "feat: add comprehensive e2e test suite with stress testing"
```

---

## Task 17: 更新文档

**Files:**
- Modify: `README.md`
- Modify: `architecture.md`
- Modify: `TROUBLESHOOTING.md`
- Modify: `docs/BATCH_CREATE_KEYS.md`

**Step 1: 更新 README.md**

- 更新架构图（Fargate + DynamoDB）
- 更新快速开始步骤（使用 setup.sh）
- 更新客户端配置示例
- 去掉 Aurora/Redis 相关内容

**Step 2: 更新 architecture.md**

- 更新网络拓扑（两层子网）
- 更新认证策略（DynamoDB custom auth）
- 更新成本分析

**Step 3: 更新 TROUBLESHOOTING.md**

- 去掉 Aurora/Redis 排障指南
- 添加 DynamoDB/Fargate 排障指南

**Step 4: 更新 BATCH_CREATE_KEYS.md**

- 改为使用 manage-keys.sh 脚本

**Step 5: Commit**

```bash
git add README.md architecture.md TROUBLESHOOTING.md docs/
git commit -m "docs: update all documentation for serverless architecture"
```

---

## 执行顺序依赖图

```
Task 1 (Dockerfile + custom_auth) ──┐
Task 2 (DynamoDB module)          ──┤
Task 3 (ECR module)               ──┤
                                    ├── Task 9 (root main.tf) ── Task 10 (post-deploy)
Task 4 (VPC 简化)                 ──┤                                    │
Task 5 (EKS Fargate)             ──┤                                    │
Task 6 (IAM 改造)                ──┘                                    │
                                                                        │
Task 7 (ConfigMap)               ──┐                                    │
Task 8 (K8s Deployment/Secret)   ──┼── Task 11 (Ingress Cognito 可选) ──┘
                                    │
Task 12 (setup.sh)               ──┤
Task 13 (manage-keys.sh)          ──┤
Task 14 (tfvars example)          ──┤
Task 15 (删除废弃模块)             ──┼── Task 16 (e2e 测试) ── Task 17 (文档)
```

**可并行的任务组：**
- Group A: Task 1, 2, 3 (新模块，互不依赖)
- Group B: Task 4, 5, 6 (改造现有模块，互不依赖)
- Group C: Task 7, 8 (K8s 配置，可并行)
- Group D: Task 12, 13 (脚本，互不依赖)
