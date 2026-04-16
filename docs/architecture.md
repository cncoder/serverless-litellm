# LiteLLM on EKS — 架构文档

> 基于全部 Terraform / Kubernetes / 脚本源码生成，最后更新：2026-03-16

---

## 1. 架构总览

```
                            ┌─────────────────────────────────┐
                            │          用户 / Claude Code      │
                            │  ANTHROPIC_BASE_URL + API Key   │
                            └──────────────┬──────────────────┘
                                           │ HTTPS
                                           ▼
                            ┌──────────────────────────────────┐
                            │   CloudFront (可选, PriceClass_All)│
                            │   X-CF-Secret 头校验              │
                            │   CachingDisabled + AllViewer     │
                            └──────────────┬──────────────────┘
                                           │ HTTP (origin-only SG)
                                           ▼
                  ┌────────────────────────────────────────────────┐
                  │            AWS WAF (可选, REGIONAL)             │
                  │  AWSManagedRulesCommonRuleSet (SQLi/XSS)       │
                  │  RateLimitLiteLLM  2000 req/5min/IP            │
                  │  RateLimitBot      2000 req/5min/IP            │
                  └────────────────────────┬───────────────────────┘
                                           │
                                           ▼
              ┌─────────────────────────────────────────────────────────┐
              │        ALB (共享, group.name=litellm-shared)            │
              │   idle_timeout=600s   TLS 1.3   ACM 证书               │
              │                                                         │
              │   Listener Rules (按优先级):                             │
              │     5  → Webhook   ${BOT_HOST}/*          无认证       │
              │    10  → API       ${LITELLM_HOST}/v1/*   Bearer Token │
              │    50  → UI        ${LITELLM_HOST}/*      Cognito 可选 │
              └──────────────────────────┬──────────────────────────────┘
                                         │ target-type: ip
                                         ▼
         ┌───────────────────────────────────────────────────────────────┐
         │              EKS Fargate Cluster (K8s 1.31)                   │
         │                                                               │
         │   Namespace: litellm                                          │
         │   ┌─────────────────────────────────────────────────────┐     │
         │   │  Deployment: litellm-deployment  (2-4 replicas)     │     │
         │   │  ┌───────────┐  ┌──────────────────────────────┐    │     │
         │   │  │ Init:     │  │ Main: litellm                │    │     │
         │   │  │ aws-cli   │→ │ ECR 自定义镜像               │    │     │
         │   │  │ Secrets   │  │ CPU: 1 / Mem: 2Gi            │    │     │
         │   │  │ Manager   │  │ Port: 4000                   │    │     │
         │   │  └───────────┘  │ config: /app/config.yaml     │    │     │
         │   │                 │ secrets: tmpfs /secrets/.env  │    │     │
         │   │                 └──────────────────────────────┘    │     │
         │   │  ServiceAccount: litellm-sa (IRSA)                  │     │
         │   │  HPA: CPU 70% → 2~4 pods                           │     │
         │   │  PDB: minAvailable=1                                │     │
         │   └─────────────────────────────────────────────────────┘     │
         │                                                               │
         │   Addons: vpc-cni, kube-proxy, coredns (Fargate mode)        │
         │   ALB Controller: Helm chart v1.8.1 (kube-system, IRSA)      │
         └────────┬──────────────────────┬──────────────────────────────┘
                  │                      │
                  ▼                      ▼
    ┌──────────────────────┐   ┌──────────────────────────┐
    │  RDS PostgreSQL 16   │   │  AWS Bedrock (us-west-2)  │
    │  db.t4g.micro, 20GB  │   │                            │
    │  Private Subnet      │   │  Opus 4.6 / 4.5 / 4.1     │
    │  SG: EKS only :5432  │   │  Sonnet 4.6 / 4.5 / 3.7   │
    │  Encrypted (KMS)     │   │  Haiku 4.5                 │
    │  Backup: 7 days      │   │  bedrock/* (wildcard)      │
    │                      │   │                            │
    │  用途:                │   │  IRSA: InvokeModel +      │
    │  - API Key 管理      │   │  InvokeModelWithResponse   │
    │  - 用量统计/预算     │   │  Stream                    │
    │  - 团队/组织管理     │   │                            │
    └──────────────────────┘   └──────────────────────────┘
```

---

## 2. Terraform Module 清单

项目使用 Terraform ≥ 1.5，Provider: AWS ~5.0 + Kubernetes ~2.25 + Helm ~2.12。

根模块 `terraform/main.tf` 编排以下子模块：

| # | Module | 路径 | 作用 | 关键资源 | 依赖 |
|---|--------|------|------|----------|------|
| 1 | **vpc** | `modules/vpc` | 网络基础设施 | VPC (10.3.0.0/16), 2 Public + 2 Private Subnets, IGW, NAT GW (单个, 成本优化), 路由表, EKS 子网标签 | 无 |
| 2 | **iam** | `modules/iam` | 基础 IAM 角色 | EKS Cluster Role (`AmazonEKSClusterPolicy`), Fargate Execution Role (`AmazonEKSFargatePodExecutionRolePolicy` + ECR ReadOnly) | 无 |
| 3 | **eks** | `modules/eks` | EKS 集群 + Fargate | EKS Cluster (1.31), Fargate Profile (litellm + kube-system namespace), Addons (vpc-cni, coredns Fargate 模式, kube-proxy), Access Entry (Terraform executor → ClusterAdmin) | vpc, iam |
| 4 | **iam-irsa** | `modules/iam-irsa` | IRSA 角色 (需 OIDC) | LiteLLM Pod Role (Bedrock InvokeModel `*` + Secrets Manager GetSecretValue), ALB Controller Role (ELB/EC2/WAF/Cognito/ACM/Shield 全量) | eks (OIDC Provider) |
| 5 | **ecr** | `modules/ecr` | 容器镜像仓库 | ECR Repository (`litellm-{env}`), scan_on_push, 生命周期策略保留 5 个镜像 | 无 |
| 6 | **rds** | `modules/rds` | PostgreSQL 数据库 | RDS PostgreSQL 16.6 (db.t4g.micro), 20GB gp3 + autoscale 100GB, Private Subnet, SG 锁 EKS, 自定义 Parameter Group (pg_stat_statements), 密码存入 Secrets Manager | vpc, eks |
| 7 | **alb-controller** | `modules/alb-controller` | Ingress 控制器 | Helm Release: aws-load-balancer-controller v1.8.1, IRSA ServiceAccount 注解 | eks, iam-irsa |
| 8 | **cloudfront** | `modules/cloudfront` | CDN + ALB 加固 (可选) | CloudFront Distribution (https-only, CachingDisabled, AllViewer), X-CF-Secret 自定义头, SG 限制 ALB 仅接受 CloudFront prefix list 入站 | post-deploy |
| 9 | **waf** | `modules/waf` | Web 防火墙 (可选) | WAFv2 Web ACL (CommonRuleSet + 双主机速率限制), null_resource 自动关联 ALB | post-deploy |
| 10 | **post-deploy** | `modules/post-deploy` | 应用部署 | Docker build → ECR push, kubectl apply 全部 K8s manifests (envsubst 变量替换), 等待 Pod Ready + ALB 创建 | 全部上游 |

**根模块额外资源：**
- `random_password.litellm_master_key` → `aws_secretsmanager_secret` (格式 `sk-<random32>`)
- OIDC Provider (`aws_iam_openid_connect_provider`) — 连接 EKS 和 IRSA
- 已有 VPC 支持：`create_vpc=false` 时跳过 vpc module，使用 `existing_vpc_id` + 自动打 EKS 子网标签

### Module 依赖图

```
vpc ─────────┐
             ├──► eks ──► OIDC Provider ──► iam-irsa ──► alb-controller ─┐
iam ─────────┘                                                           │
                                                                         ├──► post-deploy
ecr ─────────────────────────────────────────────────────────────────────┤
                                                                         │
rds ─────────────────────────────────────────────────────────────────────┘
                                                                         │
                                                              ┌──────────┘
                                                              ▼
                                                     cloudfront (可选)
                                                     waf       (可选)
```

---

## 3. Kubernetes 资源清单

所有资源部署在 `litellm` namespace，由 `post-deploy` module 通过 `envsubst` + `kubectl apply` 管理。

| 资源 | Kind | 文件 | 说明 |
|------|------|------|------|
| `litellm` | Namespace | `namespace.yaml` | 标签 `managed-by: terraform` |
| `litellm-sa` | ServiceAccount | `serviceaccount.yaml` | IRSA 注解 `eks.amazonaws.com/role-arn` |
| `litellm-config` | ConfigMap | `configmap.yaml` | LiteLLM 配置：model_list (23 条) + fallbacks + router_settings |
| `litellm-deployment` | Deployment | `deployment.yaml` | 2 replicas, RollingUpdate (maxSurge=1, maxUnavailable=0) |
| `litellm-service` | Service | `service.yaml` | ClusterIP, 80 → 4000 |
| `litellm-ingress-webhook` | Ingress | `ingress.yaml` | group.order=5, BOT_HOST, 无认证 |
| `litellm-ingress-api` | Ingress | `ingress.yaml` | group.order=10, /v1/\*, /chat/completions, /key/\*, /model/\*, /health/\*, /bedrock/\* |
| `litellm-ingress-ui` | Ingress | `ingress.yaml` / `ingress-cognito.yaml` | group.order=50, /\* 兜底, 可选 Cognito 认证 |
| `litellm-hpa` | HorizontalPodAutoscaler | `hpa.yaml` | 2-4 pods, CPU 70%, scaleUp 立即翻倍, scaleDown 5min 稳定窗口 |
| `litellm-pdb` | PodDisruptionBudget | `pdb.yaml` | minAvailable=1 |

**HTTP-only 模式：** 无 ACM 证书时自动使用 `ingress-http.yaml`（端口 80），证书签发后 `terraform apply` 自动切换 HTTPS。

### Deployment 详细架构

```
Pod
├── initContainer: secrets-init (amazon/aws-cli:latest)
│   ├── 从 Secrets Manager 拉取 LITELLM_MASTER_KEY
│   ├── 从 Secrets Manager 拉取 DB_PASSWORD
│   ├── 构造 DATABASE_URL
│   └── 写入 /secrets/.env (tmpfs, 不落盘)
│
├── container: litellm (ECR 自定义镜像)
│   ├── source /secrets/.env → exec litellm --config /app/config.yaml
│   ├── resources: 1 CPU / 2Gi (Fargate: requests = limits)
│   ├── livenessProbe:  /health/liveliness (30s delay, 15s interval)
│   └── readinessProbe: /health/liveliness (10s delay, 10s interval)
│
└── volumes:
    ├── config: ConfigMap litellm-config → /app/config.yaml
    └── secrets-volume: emptyDir (Memory, 1Mi) → /secrets/
```

---

## 4. 数据流：Claude Code → LiteLLM → Bedrock

### 4.1 请求路径 (完整链路)

```
 Claude Code                                              AWS Cloud
 ┌──────────┐    HTTPS     ┌────────────┐    HTTP     ┌───────────────┐
 │ CC Client │───────────► │ CloudFront  │──────────► │      ALB       │
 │           │             │ (可选)      │            │ (litellm-shared)│
 │ Headers:  │             │ +X-CF-Secret│            │                │
 │ Bearer    │             └────────────┘            └───────┬───────┘
 │ sk-xxx    │                                               │
 └──────────┘                                               │ target-type: ip
                                                             ▼
                                                   ┌─────────────────┐
                                                   │  LiteLLM Pod    │
                                                   │  (Fargate)      │
                                                   │                 │
                                                   │  1. 解析 Bearer │
                                                   │  2. PostgreSQL  │◄──► RDS (认证+预算)
                                                   │     验证 Key    │
                                                   │  3. 路由模型    │
                                                   │  4. 调用 Bedrock│───► Bedrock API
                                                   │  5. 流式返回    │     (IRSA 临时凭证)
                                                   │                 │
                                                   └─────────────────┘
```

### 4.2 认证流程

```
请求 → Authorization: Bearer sk-xxxxx
            │
            ▼
    LiteLLM 提取 token
            │
            ▼
    PostgreSQL 查询 LiteLLM_VerificationTokenTable
            │
            ├── 不存在 → 401 Unauthorized
            ├── 过期/超额 → 403 Forbidden
            └── 有效 → 记录用量 → 转发到 Bedrock
```

### 4.3 模型路由 + Fallback 链

```
用户请求: model="sonnet"
            │
            ▼
    model_list 查找: sonnet → bedrock/us.anthropic.claude-sonnet-4-6
            │
            ▼
    Bedrock InvokeModel (us-west-2, IRSA 凭证)
            │
            ├── 成功 → 返回
            └── 失败 (3 次) → Fallback 链:

    Opus 链:   4.6 US → 4.6 Global → 4.1 → 4.5 → Sonnet 4.6 US → ...
    Sonnet 链: 4.6 US → 4.6 Global → 4.5 → 3.7 → (循环回 4.6 US)
    Haiku 链:  4.5 → Sonnet 4.6 US

    Router: simple-shuffle, allowed_fails=3, cooldown=60s, timeout=600s
```

### 4.4 模型别名映射表

ConfigMap 中通过 `model_list` 重复条目实现别名（兼容 OpenAI + Anthropic 格式）：

| 用户输入 | 实际模型 | Bedrock Profile |
|----------|----------|-----------------|
| `opus` / `claude-opus-4-6` / `claude-opus-4-6-20250915` | Opus 4.6 | `us.anthropic.claude-opus-4-6-v1` |
| `sonnet` / `claude-sonnet-4-6` / `claude-sonnet-4-6-20250514` | Sonnet 4.6 | `us.anthropic.claude-sonnet-4-6` |
| `haiku` / `claude-haiku-4-5` / `claude-haiku-4-5-20241022` | Haiku 4.5 | `global.anthropic.claude-haiku-4-5-20251001-v1:0` |
| `claude-opus-4-5` / `claude-opus-4-5-20251101` | Opus 4.5 | `global.anthropic.claude-opus-4-5-20251101-v1:0` |
| `claude-opus-4-1` / `claude-opus-4-1-20250805` | Opus 4.1 | `us.anthropic.claude-opus-4-1-20250805-v1:0` |
| `claude-sonnet-4-5` / `claude-sonnet-4-5-20250929` | Sonnet 4.5 | `global.anthropic.claude-sonnet-4-5-20250929-v1:0` |
| `claude-sonnet-3-7` / `claude-sonnet-3-7-20250219` | Sonnet 3.7 | `us.anthropic.claude-3-7-sonnet-20250219-v1:0` |
| `bedrock/*` | 透传 | 任意 Bedrock 模型 |

---

## 5. 网络拓扑

```
VPC 10.3.0.0/16
├── Public Subnets (us-west-2a, 2b)
│   ├── Internet Gateway
│   ├── NAT Gateway (单个, 成本优化)
│   └── ALB (由 ALB Controller 创建)
│
├── Private Subnets (us-west-2a, 2b)
│   ├── EKS Fargate Pods
│   └── RDS PostgreSQL
│
└── 子网标签:
    ├── Public:  kubernetes.io/role/elb=1
    └── Private: kubernetes.io/role/internal-elb=1
```

---

## 6. 安全设计

| 层 | 机制 | 详情 |
|----|------|------|
| 边界 | CloudFront | HTTPS-only, X-CF-Secret 头验证, ALB SG 限 CF prefix list |
| 边界 | WAF | CommonRuleSet (SQLi/XSS), IP 速率限制 2000/5min |
| 传输 | TLS 1.3 | ALB: `ELBSecurityPolicy-TLS13-1-2-2021-06` |
| 认证 | LiteLLM API Key | PostgreSQL 持久化, per-key 预算/限速 |
| 认证 | Cognito (可选) | UI 管理界面 OAuth, ALB auth-on-unauthenticated-request |
| 身份 | IRSA | Pod 级别 IAM, OIDC → STS:AssumeRoleWithWebIdentity |
| 权限 | 最小权限 | LiteLLM Pod: 仅 bedrock:InvokeModel* + secretsmanager:GetSecretValue |
| 存储 | 加密 | RDS: KMS 静态加密 + TLS 传输, Secrets: tmpfs 不落盘 |
| 网络 | SG 隔离 | ALB→EKS 443, EKS→RDS 5432, 无公网直达 Pod |

---

## 7. 伸缩与高可用

- **HPA**: CPU 70% 触发, 2→4 pods, scaleUp 立即 (翻倍/+2 取大), scaleDown 5min 稳定窗口
- **PDB**: minAvailable=1, 确保滚动更新不中断
- **Rolling Update**: maxSurge=1, maxUnavailable=0 (零停机)
- **Fargate**: 按 Pod 付费, 无节点管理, 冷启动 30-60s
- **Fallback**: 模型级别自动降级, cooldown 60s 后自动恢复
- **RDS**: 7 天自动备份, 可选 Multi-AZ

---

## 8. 成本估算 (最小部署)

| 组件 | 月费 (估) | 说明 |
|------|-----------|------|
| EKS 控制平面 | $73 | 固定 |
| Fargate (2 pods × 1vCPU/2GB) | ~$70 | 按运行时间 |
| RDS db.t4g.micro | ~$12 | 单 AZ |
| NAT Gateway | ~$32 | 固定 + 数据传输 |
| ALB | ~$16 | 固定 + LCU |
| ECR | <$1 | 5 镜像 |
| CloudFront (可选) | 按流量 | |
| WAF (可选) | ~$5 + 请求费 | |
| **合计 (最小)** | **~$200/月** | 不含 Bedrock 推理费用 |
