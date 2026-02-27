# LiteLLM on EKS Serverless 架构设计文档

本文档详细说明 LiteLLM 在 AWS EKS Fargate 上的 Serverless 部署架构，使用 DynamoDB 作为认证存储，完全无需管理节点和数据库。

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
        │  - Pod Identity (原生)           │
        │  - HPA 自动扩缩 (CPU 70%)        │
        │  - PDB 中断保护 (min 1)          │
        │  - Fargate 无服务器计算          │
        │  - 无需管理节点                  │
        └────────┬────────────────────────┘
                 │
        ┌────────┼──────────┐
        ▼        ▼          ▼
    Bedrock   DynamoDB   ECR
    Claude    API Keys   Images
    (us-west-2)  (按需)
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
- 使用 Pod Identity 获取临时 AWS 凭证
- 按 Pod 实际运行时间付费

**数据层**:
- **DynamoDB**: API Keys 和用户配置存储，按需计费
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

**无数据库层的简化架构**:
- DynamoDB 是托管服务，不需要在 VPC 内运行
- 无需配置数据库子网和安全组
- 通过 VPC Endpoint 或公网访问 DynamoDB

**子网标签的关键作用**:
- `kubernetes.io/role/internal-elb=1`: 让 ALB Controller 在 Private 子网创建 ALB 目标组
- `kubernetes.io/role/elb=1`: 标记 Public 子网用于 ALB 公网监听器
- 这些标签是 AWS Load Balancer Controller 自动发现子网的必需条件

---

## 3. 认证策略 (DynamoDB custom_auth)

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

### 3.1 DynamoDB 认证实现

LiteLLM 使用 `custom_auth` 模式，API Keys 存储在 DynamoDB 表中。

**配置**:

```yaml
general_settings:
  master_key: ${LITELLM_MASTER_KEY}
  database_type: "custom"

litellm_settings:
  enable_custom_auth: true
```

**DynamoDB 表结构**:

```
表名: litellm-api-keys
分区键: token (String) - API Key (sk-xxxxx)
属性:
  - user_id (String) - 用户标识
  - created_at (Number) - 创建时间戳
  - expires_at (Number, 可选) - 过期时间
  - models (List, 可选) - 允许的模型列表
```

**认证流程**:

1. 请求携带 `Authorization: Bearer sk-xxxxx`
2. LiteLLM 从 DynamoDB 查询 token
3. 验证 token 有效性和权限
4. 转发请求到 Bedrock

**成本对比**:

| 方案 | 月成本 | 说明 |
|------|--------|------|
| Aurora Serverless v2 (0.5 ACU) | $43/月 | PostgreSQL 数据库 |
| ElastiCache Redis (t3.micro) | $13/月 | 缓存层 |
| DynamoDB 按需 | <$1/月 | 10万请求/天 |
| **总计节省** | **$55/月** | 98% 成本降低 |

**Key 管理**:

```bash
# 创建 Key
./scripts/manage-keys.sh create user_001

# 列出所有 Keys
./scripts/manage-keys.sh list

# 删除 Key
./scripts/manage-keys.sh delete sk-xxxxx

# 批量创建
./scripts/manage-keys.sh batch-create users.txt
```

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

## 6. 数据层 (DynamoDB)

### DynamoDB 表配置

```hcl
table_name: "litellm-api-keys"
billing_mode: "PAY_PER_REQUEST"  # 按需计费
hash_key: "token"

attribute {
  name = "token"
  type = "S"
}

attribute {
  name = "user_id"
  type = "S"
}

global_secondary_index {
  name            = "UserIdIndex"
  hash_key        = "user_id"
  projection_type = "ALL"
}

ttl {
  attribute_name = "expires_at"
  enabled        = true
}
```

### 设计原因

**为什么选择 DynamoDB?**

1. **Serverless 原生**:
   - 完全托管，无需配置数据库实例
   - 自动扩展，按实际请求量付费
   - 与 Fargate 完美搭配，实现完全 Serverless 架构

2. **成本优势**:
   | 访问量 | DynamoDB 成本 | Aurora 成本 | 节省 |
   |--------|--------------|-------------|------|
   | 10万/天 | $0.75/月 | $43/月 | 98% |
   | 100万/天 | $7.5/月 | $43/月 | 83% |
   | 1000万/天 | $75/月 | $150/月 | 50% |

3. **性能稳定**:
   - 单次查询延迟 < 10ms (P99)
   - 无需连接池管理
   - 无冷启动问题

4. **按需计费模式**:
   - 无需预配置读写容量
   - 自动应对流量突发
   - 适合不可预测的工作负载

5. **TTL 自动清理**:
   - 启用 TTL 功能自动删除过期 Key
   - 无需定时任务清理
   - 零维护成本

6. **GSI 灵活查询**:
   - UserIdIndex 支持按用户查询所有 Keys
   - 无需复杂的 SQL JOIN
   - 查询性能与主键一致

**数据持久化**:
- DynamoDB 自动跨 3 个 AZ 复制
- 内置时间点恢复 (PITR)
- 按需备份无额外成本

**IAM 权限配置**:
```json
{
  "Effect": "Allow",
  "Action": [
    "dynamodb:GetItem",
    "dynamodb:PutItem",
    "dynamodb:DeleteItem",
    "dynamodb:Query",
    "dynamodb:Scan"
  ],
  "Resource": [
    "arn:aws:dynamodb:*:*:table/litellm-api-keys",
    "arn:aws:dynamodb:*:*:table/litellm-api-keys/index/*"
  ]
}
```

---

## 7. 安全设计

### 身份认证和授权架构

```
LiteLLM Pod Identity (EKS Pod Identity 替代 IRSA)
    ├── 绑定 IAM Role: litellm-pod-role
    │   └── 权限策略:
    │       ├── bedrock:InvokeModel (仅限 us-west-2 Claude 模型)
    │       ├── bedrock:InvokeModelWithResponseStream
    │       ├── dynamodb:GetItem (读取 API Keys)
    │       ├── dynamodb:PutItem (创建 API Keys)
    │       ├── dynamodb:Query (查询用户 Keys)
    │       └── dynamodb:UpdateItem (更新 Key 元数据)
    │
    ├── ALB Controller Pod
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
    - Destination: 0.0.0.0/0 (Fargate 自动路由到 VPC Endpoints 访问 Bedrock/ECR/DynamoDB)
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

**EKS Pod Identity (新一代凭证机制)**:
1. **取代 IRSA 的优势**:
   - 无需手动配置 OIDC provider 和信任关系
   - Pod 直接通过 EKS Cluster endpoint 获取凭证
   - 简化 Terraform 代码 (减少 IAM policy document 复杂度)

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

3. **DynamoDB 权限的资源级限制**:
   ```json
   {
     "Effect": "Allow",
     "Action": [
       "dynamodb:GetItem",
       "dynamodb:PutItem",
       "dynamodb:Query",
       "dynamodb:UpdateItem"
     ],
     "Resource": "arn:aws:dynamodb:us-west-2:123456789012:table/litellm-api-keys"
   }
   ```
   - Pod 只能访问 API Keys 表
   - 无法访问其他 DynamoDB 表或执行扫描操作

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
- 无需 Database 层安全组（DynamoDB 通过 IAM 权限控制访问）

**数据存储的安全策略**:
1. **DynamoDB 表级加密**:
   - 默认使用 AWS 托管 KMS 密钥加密
   - 静态数据自动加密
   - 传输中数据通过 TLS 加密
2. **K8s Secrets**: 存储非敏感配置 (如模型列表、DynamoDB 表名)
   - base64 编码 (非加密，仅混淆)
   - etcd 加密可选开启 (EKS 支持 KMS 加密 etcd)

**避免的反模式**:
- ❌ 在 ConfigMap 或 Secrets 存储实际 API keys（应存在 DynamoDB）
- ❌ 给 LiteLLM Pod 赋予 `bedrock:*` 全量权限
- ❌ DynamoDB 表开启公网访问（应限制为 VPC Endpoint 访问）
- ❌ 使用 `dynamodb:Scan` 权限（性能差且成本高，用 Query 代替）

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
    ├── 5. dynamodb (API Key 存储层)
    │   ├── Outputs: table_name, table_arn
    │   └── 依赖: 无
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
        └── 依赖: eks (kubeconfig), dynamodb (table_name)
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

3. **LiteLLM Pod Role**:
   - 自定义策略: Bedrock InvokeModel + DynamoDB GetItem/PutItem/Query/UpdateItem
   - 信任关系: EKS Pod Identity 服务
   - 用途: LiteLLM Pod 调用 Bedrock 和访问 DynamoDB API Keys

4. **ALB Controller Role**:
   - 自定义策略: elasticloadbalancing:*, ec2:Describe*, wafv2:Associate*
   - 信任关系: EKS OIDC provider
   - 用途: ALB Controller 创建和管理 ALB/TargetGroup

**为什么独立模块**: IAM 策略常需调整 (如增加新权限)，独立管理避免污染其他模块；便于跨环境复用相同权限模板。

---

**3. EKS 模块** (`modules/eks`)
- 创建 EKS Cluster (Kubernetes 1.31)
- 仅控制平面，无 Managed Node Group（使用 Fargate）
- 5 个 EKS 插件:
  1. `vpc-cni`: Pod 网络 (使用 ENI)
  2. `kube-proxy`: Service 网络转发
  3. `coredns`: DNS 解析（配置为在 Fargate 上运行）
  4. `aws-ebs-csi-driver`: EBS 存储卷（可选，Fargate 支持 EBS）
  5. `eks-pod-identity-agent`: Pod Identity 凭证分发

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

**5. DynamoDB 模块** (`modules/dynamodb`)
- 表名: `litellm-api-keys`
- 分区键: `token` (String)
- 计费模式: PAY_PER_REQUEST (按需付费)
- TTL 属性: `expires_at` (自动清理过期 Keys)
- 加密: 使用 AWS 托管 KMS 密钥

**为什么独立模块**: DynamoDB 表是有状态资源，变更风险低但需谨慎；独立管理便于调整 TTL 设置和备份策略；支持跨环境复用 (dev/prod 使用不同表名)。

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
2. **依赖所有其他模块**: 需要 DynamoDB 表名、ECR URL 等变量
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

module "dynamodb" {
  source          = "./modules/dynamodb"
  table_name      = "litellm-api-keys"
}

module "post_deploy" {
  source          = "./modules/post-deploy"
  cluster_endpoint = module.eks.cluster_endpoint
  dynamodb_table_name = module.dynamodb.table_name
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
    │   └── DynamoDB: 读写容量单位、限流次数 (通过 CloudWatch Metrics)
    │
    └── 告警规则:
        ├── Pod CPU > 90% 持续 5 分钟
        ├── DynamoDB 读限流次数 > 10/min
        └── Fargate Pod 启动时间 > 2 分钟
```

### 成本优化建议

1. **Fargate Spot**: 使用 Fargate Spot 可节省 ~70% Fargate 计算成本，适合可容忍中断的工作负载
2. **DynamoDB 按需计费优化**: 监控实际读写模式，如 QPS 稳定可切换到预置容量模式节省 ~40%
3. **Single AZ 部署 (仅测试环境)**: 减少到单 AZ 可降低数据传输成本
4. **ECR 镜像清理**: 启用生命周期策略，保留最新 10 个镜像，自动删除旧镜像节省存储成本

---

## 10. 故障场景和恢复

| 故障场景 | 影响 | 自动恢复机制 | RTO |
|---------|------|------------|-----|
| 单个 LiteLLM Pod 崩溃 | 无 (HPA 维持 minReplicas=2) | Fargate 自动重启 Pod | <1min |
| Fargate 计算节点故障 | Pod 迁移到新 Fargate 节点 | K8s 自动重新调度 | <2min |
| DynamoDB 服务故障 | API Key 认证失败 | AWS 自动多 AZ 容灾 | <1min |
| DynamoDB 读写限流 | 请求延迟增加 | 自动启用突发容量或切换预置模式 | <30s |
| Bedrock Opus 4.6 US 区域故障 | 自动降级到 Opus 4.6 Global | LiteLLM 路由器降级 | <1s |
| ECR 服务故障 | 新 Pod 无法启动（已有 Pod 不受影响） | 等待 ECR 恢复或使用镜像缓存 | <5min |
| ALB 故障 | 全部流量中断 | AWS 自动替换不健康 target | <1min |

---

## 总结

本架构采用 AWS 全托管 Serverless 服务 (EKS Fargate, DynamoDB, Bedrock), 实现高可用、零运维、极致成本优化的 LiteLLM 生产部署。

核心设计原则:
1. **安全优先**: IAM 最小权限, VPC 隔离, 无硬编码凭证, DynamoDB 加密存储
2. **零运维**: Fargate 全托管计算, DynamoDB 全托管存储, 无需管理节点或数据库
3. **弹性伸缩**: HPA 自动扩 Pod, Fargate 按需分配资源, DynamoDB 自动扩容
4. **高可用**: 多 AZ 部署, PDB 保护, 降级链路, Fargate/DynamoDB 内置容灾
5. **成本极致优化**: 纯 Serverless 架构, 按需付费无固定成本, 相比传统架构节省 ~60%

适用场景: 中小规模 LLM API 代理服务 (< 1000 QPS), 追求极致成本优化和零运维。如需更高并发, 建议增加 HPA maxReplicas 和 DynamoDB 预置容量模式。
