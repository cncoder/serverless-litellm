# LiteLLM on EKS Serverless 架构设计文档

本文档详细说明 LiteLLM 在 AWS EKS Fargate 上的部署架构，使用 RDS PostgreSQL 作为数据存储，Fargate 无需管理节点。

---

## 1. 整体架构

```
用户/客户端 (程序化API调用 + 浏览器访问)
    │
    ▼
Route 53 (DNS)
    │
    ▼
AWS WAF (可选, 速率限制 2000 req/5min/IP)
    │
    ▼
Application Load Balancer (共享, group.name="litellm")
    ├── Ingress: Webhook (优先级 5, 无认证)  /api/hooks/*
    ├── Ingress: API     (优先级 10, 无认证) /chat/completions, /v1/*, /key/*, /model/*, /health/*
    └── Ingress: UI      (优先级 50, Cognito 认证) /* on api-litellm-ui.example.com
              │
              ▼
        EKS Fargate (2 AZs)
        ┌─────────────────────────────────┐
        │  LiteLLM Pods (2-10 replicas)   │
        │  - IRSA (IAM Roles for SA)       │
        │  - HPA 自动扩缩 (CPU 70%)        │
        │  - PDB 中断保护 (min 1)          │
        │  - Fargate 无服务器计算          │
        │  - 无需管理节点                  │
        └────────┬────────────────────────┘
                 │
        ┌────────┼──────────┐
        ▼        ▼          ▼
    Bedrock   RDS        ECR
    Claude    PostgreSQL Images
    (us-west-2)
```

### 架构层次说明

**外层 (边界层)**:
- **Route 53**: DNS 解析，支持两个域名 (API 域名和 UI 域名)
- **WAF**: 速率限制保护，防止 DDoS 和滥用 (可选但推荐生产环境启用)

**接入层 (ALB)**:
- 单个 ALB 处理所有流量，通过 Ingress group 共享
- 三个 Ingress 资源使用不同优先级规则路由流量

**计算层 (EKS Fargate)**:
- LiteLLM Pod 运行在 Fargate 上，完全 Serverless
- 无需管理节点、无需配置 Auto Scaling Group
- 使用 IRSA 获取临时 AWS 凭证
- 按 Pod 实际运行时间付费

**数据层**:
- **RDS PostgreSQL**: API Keys、用户配置、预算等数据存储（LiteLLM 原生支持）
- **ECR**: 容器镜像存储
- **Bedrock**: 实际 LLM 推理服务

---

## 2. 网络拓扑

### VPC 两层子网设计

```
VPC (10.0.0.0/16)
│
├── Public Subnets (10.0.1.0/24, 10.0.2.0/24)
│   └── Application Load Balancer
│
└── Private Subnets (10.0.11.0/24, 10.0.12.0/24)
    ├── EKS Fargate Pods (无节点)
    ├── LiteLLM Pods
    └── kubernetes.io/role/internal-elb=1 tag (ALB 目标组)
```

### 设计原因

**两层设计的 Serverless 优化**:
1. **Public 层**: 仅放置 ALB，不需要 NAT Gateway（Fargate 自动处理出站流量）
2. **Private 层**: Fargate Pods 运行在此，无需节点管理

**无 NAT Gateway 的成本优势**:
- Fargate 原生支持出站互联网访问，无需 NAT Gateway
- 节省 $32+/月 的 NAT Gateway 固定成本
- 避免数据传输费用 ($0.045/GB)

**数据库层**:
- RDS PostgreSQL 部署在 Private 子网内
- 通过安全组限制仅允许 EKS Pod 访问
- LiteLLM 原生支持 PostgreSQL 作为数据存储

**子网标签的关键作用**:
- `kubernetes.io/role/internal-elb=1`: 让 ALB Controller 在 Private 子网创建 ALB 目标组
- `kubernetes.io/role/elb=1`: 标记 Public 子网用于 ALB 公网监听器
- 这些标签是 AWS Load Balancer Controller 自动发现子网的必需条件

---

## 3. 认证策略 (LiteLLM Native Auth)

### 三 Ingress 共享 ALB 设计

```yaml
# Ingress 1: Webhook (优先级 5)
alb.ingress.kubernetes.io/group.name: litellm
alb.ingress.kubernetes.io/group.order: "5"
路径: /api/hooks/*
认证: 无 (允许外部 webhook 回调)

# Ingress 2: API (优先级 10)
alb.ingress.kubernetes.io/group.name: litellm
alb.ingress.kubernetes.io/group.order: "10"
路径: /chat/completions, /v1/*, /key/*, /model/*, /health/*
认证: 无 (使用 LiteLLM Bearer Token 认证)

# Ingress 3: UI (优先级 50)
alb.ingress.kubernetes.io/group.name: litellm
alb.ingress.kubernetes.io/group.order: "50"
主机: api-litellm-ui.example.com
路径: /*
认证: Cognito User Pool (浏览器 OAuth 流程)
```

### 设计原因详解

**为什么 API 路径不用 Cognito 认证?**
1. **程序化调用需求**: `/chat/completions` 等 API 由代码调用，无法完成 OAuth 浏览器重定向流程
2. **标准兼容**: OpenAI SDK 期望简单的 `Authorization: Bearer sk-xxx` header
3. **LiteLLM 内置认证**: 已有 API key 管理和速率限制机制，无需 ALB 层认证

**为什么 UI 需要 Cognito?**
1. **管理界面保护**: `/ui` 控制台可创建/删除 API key、查看预算，必须严格控制访问
2. **用户友好**: 浏览器访问自动跳转到 Cognito 登录页，支持 MFA
3. **会话管理**: Cognito 提供 JWT token 管理和自动续期

**为什么 Webhook 路径完全开放?**
1. **外部服务回调**: Slack/Discord webhook 从公网发起，无法提前共享认证 token
2. **验证机制**: 通常通过签名验证 (如 Slack 的 `X-Slack-Signature`) 或 secret token 在请求体中
3. **限流保护**: 依赖 WAF 速率限制防止滥用

**优先级数字的匹配逻辑**:
- 数字越小越优先匹配
- Priority 5 的 `/api/hooks/*` 先于 Priority 10 的 `/v1/*` 检查
- Priority 50 的 `/*` 通配符作为兜底，确保 UI 路径不被 API 规则误捕获
- 这防止了路径冲突 (如 `/api/hooks/callback` 不会被 `/v1/*` 误匹配)

**共享 ALB 的成本优势**:
- 每个 ALB 约 $16/月基础费用 + LCU 使用费
- 三个 Ingress 共享一个 ALB 节省 $32/月
- 通过 Listener Rules 实现流量路由，无性能损耗

---

### 3.1 PostgreSQL 认证实现

LiteLLM 使用原生 PostgreSQL 模式管理 API Keys，通过 Admin UI 创建和管理。

**配置**:

```yaml
general_settings:
  master_key: ${LITELLM_MASTER_KEY}
  database_url: os.environ/DATABASE_URL
```

**认证流程**:

1. 请求携带 `Authorization: Bearer sk-xxxxx`
2. LiteLLM 从 PostgreSQL 查询 token
3. 验证 token 有效性和权限（支持预算、速率限制等）
4. 转发请求到 Bedrock

**Key 管理**:

通过 LiteLLM Admin UI (`/ui`) 进行：
- 创建/删除 API Key
- 设置用户预算和速率限制
- 查看使用统计
- 管理团队和组织

---

## 4. 降级策略 (Fallback Chain)

### 降级链路设计

```
主要推理模型降级:
Opus 4.6 US ──► Opus 4.6 Global ──► Opus 4.5 ──► Sonnet 4.6 US ──► Sonnet 4.6 Global ──► Sonnet 4.5 ──► Sonnet 3.7 ──► Sonnet 3.5

轻量模型降级:
Haiku 4.5 ──► Sonnet 3.5

路由器设置:
- allowed_fails: 3 (连续 3 次失败后标记模型不可用)
- cooldown_time: 60 (60秒后自动重试该模型)
- retry_after: 0 (立即尝试下一个降级模型)
```

### 设计原因

**同模型跨区域优先原则**:
1. **US → Global**: 先尝试同一模型的不同部署区域
   - 处理区域性服务中断 (如 us-west-2 AZ 故障)
   - 保持模型能力一致性 (Opus 4.6 US 和 Global 性能相同)
2. **跨区域比降级模型更优**: 避免性能下降和输出质量变化

**逐级降级到低版本模型**:
1. **Opus → Opus 旧版 → Sonnet 新版**: 渐进降级策略
   - 先尝试旧版 Opus (如 4.5) 保持高质量
   - 再降级到新版 Sonnet (如 4.6) 平衡速度和质量
2. **Sonnet 3.7 → 3.5**: 最后回退到成熟稳定版本
   - 3.5 版本部署时间长，可用性最高

**Haiku 单独链路的特殊处理**:
- Haiku 4.5 直接跳到 Sonnet 3.5 (跳过 Opus)
- 原因: Haiku 用于低延迟场景，降级到 Opus 会违背延迟需求
- Sonnet 3.5 是速度和能力的折中选择

**路由器参数调优**:
- `allowed_fails=3`: 避免单次偶发错误导致模型标记不可用
- `cooldown_time=60`: 给服务恢复留足时间，但不会太久影响可用性
- `retry_after=0`: 降级要快速，用户无感知切换

**健康检查机制**:
```python
# LiteLLM 自动执行
每 60 秒检查被标记为 "不可用" 的模型
发送轻量级健康检查请求
成功后自动恢复到 available 池
```

---

## 5. Fargate 扩容策略

### HPA (Horizontal Pod Autoscaler) 配置

Fargate 与 EC2 Node Group 扩容的关键区别：
- **无需节点预留**: 新 Pod 直接在 Fargate 上启动，无需等待节点扩容
- **启动时间**: Fargate Pod 启动需 30-60秒（冷启动），比 EC2 Node 慢
- **成本模型**: 按 Pod 实际运行时间计费，无闲置节点成本

```yaml
minReplicas: 2
maxReplicas: 10
metrics:
  - CPU: 70%
  - Memory: 80%
behavior:
  scaleDown:
    stabilizationWindowSeconds: 300
    policies:
      - type: Percent
        value: 50
        periodSeconds: 60
  scaleUp:
    stabilizationWindowSeconds: 0
    policies:
      - type: Percent (优先)
        value: 100
        periodSeconds: 30
      - type: Pods (备选)
        value: 2
        periodSeconds: 60
    selectPolicy: Max
```

### PDB (Pod Disruption Budget) 配置

```yaml
minAvailable: 1
```

### 设计原因

**最小 2 副本的 HA 基线**:
- 单副本无法应对节点故障或 Pod 崩溃
- 2 副本确保始终有 1 个 Pod 响应请求
- 跨 AZ 部署 (EKS node group 配置 3 个 AZ)，提升可用性

**最大 10 副本的成本控制**:
- LiteLLM 作为代理层，本身计算开销小 (主要是网络 I/O)
- 10 个 Pod 足以处理大部分生产流量
- 避免无限扩容导致成本失控
- 如需更高并发，应优化上游限流或增加 maxReplicas

**CPU 70% 阈值的留白策略**:
- **为什么不是 80% 或 90%**: LiteLLM 主要瓶颈是 I/O (等待 Bedrock 响应)，CPU 使用率波动大
- 70% 是经验值: 留 30% headroom 应对突发流量
- 避免频繁扩缩: CPU 接近 100% 时可能已出现排队

**Memory 80% 阈值的稳定性考量**:
- 内存使用比 CPU 稳定 (缓存、连接池相对恒定)
- 80% 是安全线: 避免 OOMKilled，但不过于保守浪费资源
- LiteLLM 内存占用主要来自 Redis 连接和请求缓冲

**Scale Down 稳定窗口 300 秒**:
- **防抖动**: LLM 流量特征是突发性 (大量请求集中到达，然后低谷)
- 5 分钟观察期避免"扩容 → 流量下降 → 缩容 → 流量再来 → 又扩容"的抖动
- 每次缩容最多减少 50%: 渐进式收缩，避免过度缩容导致下次请求延迟

**Scale Up 激进策略**:
- **无稳定窗口**: 流量上升时立即扩容 (stabilizationWindowSeconds: 0)
- **双策略取最大值**:
  - 百分比策略: 30 秒内翻倍 (2 → 4 → 8)
  - 固定策略: 60 秒内 +2 个 Pod (适用于小规模时，如 2 → 4)
  - selectPolicy: Max 确保扩得够快
- 原因: 宁可暂时多付费，也不能让用户请求超时

**PDB minAvailable=1 的中断保护**:
- **Fargate 场景**: Fargate Pod 重启时自动调度到新的计算资源
- 保证"至少 1 个 Pod 可用"，避免全部 Pod 同时被驱逐
- 不阻止紧急操作 (强制删除仍会执行)
- 配合 minReplicas=2: 正常情况下有 2 个 Pod，中断时保留 1 个

**资源请求和限制** (在 Deployment 中配置):
```yaml
resources:
  requests:
    cpu: 500m      # HPA 基于 requests 计算百分比
    memory: 512Mi
  limits:
    memory: 1Gi    # 防止内存泄漏影响节点
```

---

## 6. 数据层 (RDS PostgreSQL)

### RDS 配置

```hcl
engine               = "postgres"
engine_version       = "15"
instance_class       = "db.t4g.micro"
allocated_storage    = 20
db_name              = "litellm"
multi_az             = false          # 生产环境建议开启
skip_final_snapshot  = false
backup_retention     = 7              # 7 天自动备份
```

### 设计原因

**为什么选择 RDS PostgreSQL?**

1. **LiteLLM 原生支持**:
   - 设置 `DATABASE_URL` 即可启用完整功能
   - 内置 API Key 管理、用户预算、速率限制、使用统计
   - Admin UI (`/ui`) 提供图形化管理界面
   - 无需自定义认证代码

2. **功能完整**:
   - 支持团队和组织管理
   - 支持 per-key 预算控制
   - 支持使用量追踪和分析
   - Schema 迁移由 LiteLLM 自动管理

3. **数据持久化**:
   - RDS 自动备份（7 天保留期）
   - 支持手动快照
   - 可选 Multi-AZ 高可用部署

4. **安全性**:
   - 部署在 Private 子网，不暴露公网
   - 安全组限制仅允许 EKS Pod 访问
   - 传输加密 (TLS) + 静态加密 (KMS)

---

## 7. 安全设计

### 身份认证和授权架构

```
LiteLLM IRSA (IAM Roles for Service Accounts)
    ├── 绑定 IAM Role: litellm-irsa-role
    │   └── 权限策略:
    │       ├── bedrock:InvokeModel (仅限 us-west-2 Claude 模型)
    │       └── bedrock:InvokeModelWithResponseStream
    │
    ├── ALB Controller Pod (IRSA)
    │   └── IAM Role: alb-controller-role
    │       ├── elasticloadbalancing:* (创建/删除 ALB/TargetGroup)
    │       ├── ec2:DescribeSubnets (发现子网)
    │       ├── wafv2:AssociateWebACL (关联 WAF)
    │       └── cognito-idp:DescribeUserPool (Cognito 认证)
    │
    └── EKS Fargate Profile Execution Role: eks-fargate-role
        ├── AmazonEKSFargatePodExecutionRolePolicy
        └── AmazonEC2ContainerRegistryReadOnly
```

### 网络安全组规则

```
EKS Cluster Security Group (Private 层):
  Inbound:
    - Source: ALB Security Group
    - Port: 443 (Fargate Pod 端口)
    - Protocol: TCP
  Outbound:
    - Destination: 0.0.0.0/0 (Fargate 自动路由到 VPC Endpoints 访问 Bedrock/ECR)
    - All ports, All protocols

ALB Security Group (Public 层):
  Inbound:
    - Source: 0.0.0.0/0
    - Port: 443 (HTTPS)
    - Protocol: TCP
  Outbound:
    - Destination: EKS Cluster Security Group
    - Port: 443
    - Protocol: TCP
```

### 设计原因

**IRSA (IAM Roles for Service Accounts)**:
1. **通过 OIDC Provider 实现 Pod 级别权限**:
   - EKS 集群创建 OIDC provider
   - IAM Role 信任策略绑定到特定 ServiceAccount
   - Pod 通过 `sts:AssumeRoleWithWebIdentity` 获取临时凭证

2. **bedrock:InvokeModel* 权限的最小化**:
   ```json
   {
     "Effect": "Allow",
     "Action": [
       "bedrock:InvokeModel",
       "bedrock:InvokeModelWithResponseStream"
     ],
     "Resource": [
       "arn:aws:bedrock:us-west-2::foundation-model/us.anthropic.claude-*",
       "arn:aws:bedrock:us-west-2::foundation-model/global.anthropic.claude-*"
     ]
   }
   ```
   - 仅允许 Claude 系列模型，拒绝其他模型 (如 Titan, Llama)
   - 仅限 us-west-2 区域 (避免跨区调用导致额外费用)
   - 不包含管理权限 (如 CreateModelCustomizationJob)

**ALB Controller 独立 IAM 角色**:
- 分离控制平面 (ALB Controller) 和数据平面 (LiteLLM Pod) 权限
- ALB Controller 需要 `elasticloadbalancing:*` 和 `ec2:Describe*` 等管理权限
- 遵循最小权限原则: 各组件只拿必需权限

**WAF 速率限制 (可选但强烈推荐)**:
```hcl
rate_based_statement {
  limit: 2000
  aggregate_key_type: "IP"
  scope_down_statement {
    byte_match_statement {
      search_string: "/chat/completions"
      positional_constraint: "CONTAINS"
    }
  }
}
```
- 限制单 IP 5 分钟内最多 2000 请求
- 防止滥用或 DDoS 攻击
- 针对高频 API 端点 (如 `/chat/completions`)

**安全组设计的"最小化信任边界"**:
- Fargate Pod 仅允许 ALB 入站流量（443 端口）
- ALB 只开放 443 端口，禁用 80 (强制 HTTPS)
- RDS 安全组限制仅允许 EKS Pod 入站访问（5432 端口）

**数据存储的安全策略**:
1. **RDS 加密**:
   - 静态加密使用 AWS 托管 KMS 密钥
   - 传输加密通过 TLS
   - 部署在 Private 子网，不暴露公网
2. **K8s Secrets**: 存储敏感配置 (DATABASE_URL、LITELLM_MASTER_KEY)
   - base64 编码 (非加密，仅混淆)
   - etcd 加密可选开启 (EKS 支持 KMS 加密 etcd)

**避免的反模式**:
- ❌ 在 ConfigMap 存储数据库密码（应放在 Secret 中）
- ❌ 给 LiteLLM Pod 赋予 `bedrock:*` 全量权限
- ❌ RDS 开启公网访问（应限制在 Private 子网）
- ❌ 使用硬编码密码（应使用 Secrets Manager 或 K8s Secret）

---

## 8. Terraform 模块设计

### 模块依赖拓扑

```
terraform/
├── main.tf (根模块, 调用所有子模块)
├── variables.tf (全局变量定义)
├── outputs.tf (输出 ALB DNS, EKS endpoint, ECR URL)
│
└── modules/
    ├── 1. vpc (基础网络层)
    │   ├── Outputs: vpc_id, public_subnets, private_subnets
    │   └── 依赖: 无
    │
    ├── 2. iam (身份权限层)
    │   ├── Outputs: cluster_role_arn, fargate_profile_role_arn, pod_role_arn, alb_controller_role_arn
    │   └── 依赖: 无 (仅需 EKS cluster name 变量)
    │
    ├── 3. eks (计算集群层)
    │   ├── Outputs: cluster_id, cluster_endpoint, oidc_provider_arn
    │   └── 依赖: vpc (subnet IDs), iam (role ARNs)
    │
    ├── 4. fargate-profile (Serverless 计算配置)
    │   ├── Outputs: fargate_profile_id, fargate_profile_status
    │   └── 依赖: eks (cluster_name), vpc (private_subnets), iam (fargate_profile_role_arn)
    │
    ├── 5. rds (数据库层)
    │   ├── Outputs: db_endpoint, db_name
    │   └── 依赖: vpc (private_subnets)
    │
    ├── 6. ecr (镜像仓库层)
    │   ├── Outputs: repository_url
    │   └── 依赖: 无
    │
    ├── 7. alb-controller (Ingress 控制器)
    │   ├── Outputs: helm_release_status
    │   └── 依赖: eks (cluster info), iam (ALB controller role)
    │
    ├── 8. waf (边界安全层, 可选)
    │   ├── Outputs: web_acl_arn
    │   └── 依赖: 无 (WAF 是 global/regional 资源)
    │
    └── 9. post-deploy (应用部署层)
        ├── 使用 local-exec 和 kubectl apply 部署 K8s manifests
        └── 依赖: eks (kubeconfig), rds (db_endpoint)
```

### 各模块职责详解

**1. VPC 模块** (`modules/vpc`)
- 创建 VPC (10.0.0.0/16)
- 3 个 Public 子网 + 3 个 Private 子网
- Internet Gateway (无需 NAT Gateway，Fargate 自动处理出站流量)
- 路由表配置:
  - Public: 默认路由到 IGW
  - Private: 默认路由到 IGW (Fargate 使用)
- 子网标签: `kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`

**为什么独立模块**: 网络是最底层基础设施，所有其他资源依赖它；独立管理便于重用和网络变更隔离。

---

**2. IAM 模块** (`modules/iam`)
创建 4 个 IAM 角色:
1. **EKS Cluster Role**:
   - 附加策略: `AmazonEKSClusterPolicy`
   - 信任关系: `eks.amazonaws.com`
   - 用途: EKS 控制平面调用 AWS API (如创建 ENI)

2. **EKS Fargate Profile Execution Role**:
   - 附加策略: `AmazonEKSFargatePodExecutionRolePolicy`, `AmazonEC2ContainerRegistryReadOnly`
   - 信任关系: `eks-fargate-pods.amazonaws.com`
   - 用途: Fargate 拉取镜像、配置网络

3. **LiteLLM Pod Role (IRSA)**:
   - 自定义策略: Bedrock InvokeModel
   - 信任关系: EKS OIDC provider (sts:AssumeRoleWithWebIdentity)
   - 用途: LiteLLM Pod 调用 Bedrock 推理服务

4. **ALB Controller Role**:
   - 自定义策略: elasticloadbalancing:*, ec2:Describe*, wafv2:Associate*
   - 信任关系: EKS OIDC provider
   - 用途: ALB Controller 创建和管理 ALB/TargetGroup

**为什么独立模块**: IAM 策略常需调整 (如增加新权限)，独立管理避免污染其他模块；便于跨环境复用相同权限模板。

---

**3. EKS 模块** (`modules/eks`)
- 创建 EKS Cluster (Kubernetes 1.31)
- 仅控制平面，无 Managed Node Group（使用 Fargate）
- 4 个 EKS 插件:
  1. `vpc-cni`: Pod 网络 (使用 ENI)
  2. `kube-proxy`: Service 网络转发
  3. `coredns`: DNS 解析（配置为在 Fargate 上运行）
  4. `aws-ebs-csi-driver`: EBS 存储卷（可选，Fargate 支持 EBS）

**为什么独立模块**: EKS 集群是核心计算资源，生命周期独立；与 Fargate Profile 分离管理便于独立更新集群版本。

---

**4. Fargate Profile 模块** (`modules/fargate-profile`)
- 创建 EKS Fargate Profile
- 选择器:
  - namespace: `litellm`, `kube-system` (coredns)
  - labels: `app=litellm`, `k8s-app=kube-dns`
- 子网: private_subnets (跨 3 个 AZ)
- 执行角色: fargate_profile_role_arn

**为什么独立模块**: Fargate Profile 定义 Pod 调度策略，独立管理便于添加新 namespace 或调整选择器；便于多环境复用 (dev/prod 使用不同 Profile)。

---

**5. RDS 模块** (`modules/rds`)
- 引擎: PostgreSQL 15
- 实例类型: db.t4g.micro (可调整)
- 存储: 20GB gp3
- 自动备份: 7 天保留期
- 加密: 使用 AWS 托管 KMS 密钥
- 子网组: Private 子网

**为什么独立模块**: RDS 是有状态资源，变更风险高需谨慎；独立管理便于调整实例类型和备份策略；支持跨环境复用 (dev/prod 使用不同实例)。

---

**6. ECR 模块** (`modules/ecr`)
- 创建 ECR 仓库: `litellm`
- 镜像扫描: 开启 (on_push)
- 生命周期策略: 保留最新 10 个镜像

**为什么独立模块**: 镜像仓库可被多个 EKS 集群共享；独立管理便于跨项目复用；生命周期策略独立调整避免误删镜像。

---

**7. ALB Controller 模块** (`modules/alb-controller`)
- 使用 Helm Chart 部署 AWS Load Balancer Controller
- Chart version: 1.8.1
- 配置:
  - `clusterName`: EKS 集群名称
  - `serviceAccount.annotations`: 绑定 ALB Controller IAM 角色
  - `region`: us-west-2

**为什么独立模块**: Helm release 是 Kubernetes 层资源，但依赖 AWS IAM 角色；独立管理便于升级 chart 版本而不影响 EKS 集群本身。

---

**8. WAF 模块** (`modules/waf`, 可选)
- 创建 WAFv2 Web ACL
- 规则:
  1. 速率限制: 2000 req/5min/IP
  2. IP 白名单/黑名单 (可选)
- 关联到 ALB

**为什么独立模块**: WAF 是边界安全策略，可选功能 (开发环境可不启用)；独立管理便于调整规则 (如修改速率限制阈值) 而不触碰 ALB 配置。

---

**9. Post-Deploy 模块** (`modules/post-deploy`)
使用 `local-exec` provisioner 执行:
```bash
# 1. 渲染 K8s manifests 模板
envsubst < kubernetes/configmap.yaml.tpl > /tmp/configmap.yaml
envsubst < kubernetes/secret.yaml.tpl > /tmp/secret.yaml
envsubst < kubernetes/deployment.yaml.tpl > /tmp/deployment.yaml
envsubst < kubernetes/service.yaml.tpl > /tmp/service.yaml
envsubst < kubernetes/ingress-api.yaml.tpl > /tmp/ingress-api.yaml
envsubst < kubernetes/ingress-ui.yaml.tpl > /tmp/ingress-ui.yaml
envsubst < kubernetes/hpa.yaml.tpl > /tmp/hpa.yaml

# 2. 应用到 EKS 集群
kubectl apply -f /tmp/configmap.yaml
kubectl apply -f /tmp/secret.yaml
kubectl apply -f /tmp/deployment.yaml
kubectl apply -f /tmp/service.yaml
kubectl apply -f /tmp/ingress-api.yaml
kubectl apply -f /tmp/ingress-ui.yaml
kubectl apply -f /tmp/hpa.yaml
```

**为什么独立模块**:
1. **Terraform 管理 AWS 资源，kubectl 管理 K8s 资源**: 职责分离，避免 Terraform 状态文件混入 K8s 资源
2. **依赖所有其他模块**: 需要 RDS 连接信息、ECR URL 等变量
3. **幂等性保证**: `kubectl apply` 是幂等操作，重复执行不会出错
4. **便于调试**: local-exec 输出可见，方便排查 K8s 部署失败原因

**替代方案对比**:
- ❌ 使用 Terraform Kubernetes Provider: 会将 K8s 资源写入 tfstate，混合 IaC 和应用部署
- ❌ 手动 kubectl apply: 不可复现，难以版本控制
- ✅ local-exec + envsubst: 简单可靠，模板化配置便于多环境复用

---

### 模块间变量传递示例

```hcl
# terraform/main.tf
module "vpc" {
  source = "./modules/vpc"
  cidr   = "10.0.0.0/16"
}

module "eks" {
  source          = "./modules/eks"
  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets
  cluster_role_arn = module.iam.cluster_role_arn
}

module "fargate_profile" {
  source          = "./modules/fargate-profile"
  cluster_name    = module.eks.cluster_name
  private_subnets = module.vpc.private_subnets
  fargate_profile_role_arn = module.iam.fargate_profile_role_arn
}

module "rds" {
  source          = "./modules/rds"
  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets
}

module "post_deploy" {
  source          = "./modules/post-deploy"
  cluster_endpoint = module.eks.cluster_endpoint
  db_endpoint     = module.rds.db_endpoint
  ecr_repository_url = module.ecr.repository_url
}
```

---

## 9. 运维和监控

### 日志收集 (未在初版实现, 生产建议)

```
Fargate Pod Logs
    │
    ▼
AWS Firehose for Fluent Bit (Fargate 内置日志路由)
    │
    ▼
CloudWatch Logs (Log Group: /aws/eks/litellm/application)
```

推荐配置:
- 保留期: 7 天 (降低成本)
- 过滤器: 仅收集 ERROR 和 WARN 级别日志
- 成本估算: ~$5/月 (10GB 日志)
- Fargate 自动将 stdout/stderr 路由到 CloudWatch，无需 DaemonSet

### 指标监控 (未在初版实现, 生产建议)

```
Prometheus (Helm Chart，需配置在 Fargate)
    ├── 采集指标:
    │   ├── LiteLLM: /metrics 端点 (请求延迟, 降级次数, token 使用量)
    │   ├── Fargate Pod: CPU, Memory (通过 Kubernetes Metrics Server)
    │   └── RDS: CPU、连接数、查询延迟 (通过 CloudWatch Metrics)
    │
    └── 告警规则:
        ├── Pod CPU > 90% 持续 5 分钟
        ├── RDS CPU > 80% 持续 5 分钟
        └── Fargate Pod 启动时间 > 2 分钟
```

### 成本优化建议

1. **Fargate Spot**: 使用 Fargate Spot 可节省 ~70% Fargate 计算成本，适合可容忍中断的工作负载
2. **RDS 实例选型优化**: 根据实际连接数和查询负载选择合适实例类型，测试环境可用 db.t4g.micro 节省成本
3. **Single AZ 部署 (仅测试环境)**: 减少到单 AZ 可降低数据传输成本
4. **ECR 镜像清理**: 启用生命周期策略，保留最新 10 个镜像，自动删除旧镜像节省存储成本

---

## 10. 故障场景和恢复

| 故障场景 | 影响 | 自动恢复机制 | RTO |
|---------|------|------------|-----|
| 单个 LiteLLM Pod 崩溃 | 无 (HPA 维持 minReplicas=2) | Fargate 自动重启 Pod | <1min |
| Fargate 计算节点故障 | Pod 迁移到新 Fargate 节点 | K8s 自动重新调度 | <2min |
| RDS PostgreSQL 故障 | API Key 认证失败 | Multi-AZ 自动故障切换 | <1min |
| RDS 连接数耗尽 | 新请求排队等待 | 连接池自动回收 + HPA 扩容分散负载 | <30s |
| Bedrock Opus 4.6 US 区域故障 | 自动降级到 Opus 4.6 Global | LiteLLM 路由器降级 | <1s |
| ECR 服务故障 | 新 Pod 无法启动（已有 Pod 不受影响） | 等待 ECR 恢复或使用镜像缓存 | <5min |
| ALB 故障 | 全部流量中断 | AWS 自动替换不健康 target | <1min |

---

## 总结

本架构采用 AWS 托管服务 (EKS Fargate, RDS PostgreSQL, Bedrock), 实现高可用、低运维、成本优化的 LiteLLM 生产部署。

核心设计原则:
1. **安全优先**: IAM 最小权限, VPC 隔离, 无硬编码凭证, RDS 加密存储
2. **低运维**: Fargate 全托管计算, RDS 托管数据库, 无需管理节点
3. **弹性伸缩**: HPA 自动扩 Pod, Fargate 按需分配资源
4. **高可用**: 多 AZ 部署, PDB 保护, 降级链路, RDS Multi-AZ 容灾
5. **成本优化**: Fargate Serverless 计算 + RDS 按需实例, 相比传统架构节省 ~50%

适用场景: 中小规模 LLM API 代理服务 (< 1000 QPS), 追求低运维和成本优化。如需更高并发, 建议增加 HPA maxReplicas 和 RDS 实例规格。
