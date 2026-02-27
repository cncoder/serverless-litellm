# 手动部署指南

## 前置条件

确保以下工具已安装并配置：

- **AWS CLI v2** - `aws configure` 配置好凭证
- **Terraform** >= 1.5
- **kubectl** - Kubernetes 命令行工具
- **Helm 3** - Kubernetes 包管理器
- **envsubst** - 变量替换工具（`gettext` 包）

可选工具：**jq**（JSON 处理）、**hey** / **ab**（压力测试）

---

## Step 1: 配置 Terraform 变量

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars
```

关键配置项：

```hcl
project_name = "litellm"
environment  = "prod"
aws_region   = "eu-central-1"

# 域名
litellm_host = "litellm.example.com"
bot_host     = "bot.example.com"

# ACM 证书（两阶段部署说明见下方）
acm_certificate_arn = ""

# 可选: 使用已有 VPC
# create_vpc = false
# existing_vpc_id = "vpc-xxx"
```

---

## Step 2: 两阶段 ACM 证书部署

域名在 Cloudflare 或其他 DNS 服务商时，ACM 无法自动验证，需要两阶段部署：

### 阶段 1 - HTTP only（无证书）

```hcl
# terraform.tfvars
acm_certificate_arn = ""
```

```bash
terraform init
terraform apply
```

部署完成后：
1. 获取 ALB DNS：`kubectl get ingress -n litellm litellm-ingress-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`
2. 在 Cloudflare / DNS 服务商创建 CNAME：`litellm.example.com → <ALB DNS>`
3. 在 AWS ACM 申请证书，选 **DNS 验证**
4. 在 DNS 服务商添加 ACM 给出的 CNAME 验证记录
5. 等待证书状态变为 **Issued**（通常 5-30 分钟）

### 阶段 2 - 切换 HTTPS

```hcl
# terraform.tfvars
acm_certificate_arn = "arn:aws:acm:eu-central-1:123456789012:certificate/xxx"
```

```bash
terraform apply
```

Terraform 会自动将 HTTP Ingress 替换为 HTTPS Ingress。

---

## Step 3: 部署基础设施

```bash
# 预览变更
terraform plan

# 执行部署（约 15-20 分钟）
terraform apply
```

Terraform 输出内容：
- `eks_cluster_name` - EKS 集群名
- `dynamodb_table_name` - DynamoDB 表名
- `litellm_master_key` - Master Key（敏感，使用 `-raw` 参数获取）
- `ecr_repository_url` - ECR 仓库地址
- `kubeconfig_command` - 配置 kubectl 的命令

---

## Step 4: 配置 kubectl

```bash
aws eks update-kubeconfig --name litellm-eks-prod --region eu-central-1
```

---

## Step 5: 验证部署

```bash
# 检查 Pod 状态
kubectl get pods -n litellm

# 查看 Ingress（获取 ALB DNS）
kubectl get ingress -n litellm

# 健康检查
curl https://litellm.example.com/health/liveliness
```

预期 Pod 状态：
```
NAME                           READY   STATUS    RESTARTS   AGE
litellm-xxxxxxxxxx-xxxxx       1/1     Running   0          2m
litellm-xxxxxxxxxx-xxxxx       1/1     Running   0          2m
```

---

## 日常维护

| 变更类型 | 命令 |
|---------|------|
| 更新 LiteLLM 配置（模型、路由） | `kubectl apply -k kubernetes/` |
| 更新镜像版本 | 修改 `kubernetes/deployment.yaml` → `kubectl apply -k kubernetes/` |
| 调整副本数 / HPA | 修改 `kubernetes/hpa.yaml` → `kubectl apply -k kubernetes/` |
| 变更基础设施（VPC、EKS） | `terraform apply` |

---

## 使用已有 VPC

如果已有 VPC，可以跳过 VPC 创建：

```hcl
# terraform.tfvars
create_vpc                  = false
existing_vpc_id             = "vpc-0123456789abcdef0"
existing_public_subnet_ids  = ["subnet-aaa", "subnet-bbb"]
existing_private_subnet_ids = ["subnet-ccc", "subnet-ddd"]
```

---

## 启用可选组件

### WAF

```hcl
enable_waf = true
```

WAF 规则：
- `AWSManagedRulesCommonRuleSet` - SQLi、XSS 防护
- `RateLimitLiteLLM` - 2000 req/5min/IP
- `RateLimitBot` - 2000 req/5min/IP

### Cognito 认证

```hcl
enable_cognito              = true
cognito_user_pool_arn       = "arn:aws:cognito-idp:..."
cognito_user_pool_client_id = "xxxxxx"
cognito_user_pool_domain    = "your-domain"
```

启用后，访问 LiteLLM UI (`/ui`) 需要 Cognito 登录；API 路径 (`/v1/*`, `/key/*`) 仍使用 API Key 认证。
