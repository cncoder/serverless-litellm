# LiteLLM on EKS 故障排查指南

本文档基于真实生产环境部署经验整理,记录实际遇到的问题和解决方案。

## 目录

1. [容器平台问题](#1-容器平台问题)
2. [网络和负载均衡](#2-网络和负载均衡)
3. [基础设施超时](#3-基础设施超时)
4. [Fargate 特有问题](#4-fargate-特有问题)
5. [AWS 权限和服务](#5-aws-权限和服务)
6. [配置和更新](#6-配置和更新)
7. [脚本兼容性](#7-脚本兼容性)
8. [常用调试命令](#8-常用调试命令)

---

## 1. 容器平台问题

### 1.1 Pod CrashLoopBackOff - exec format error

**现象**
```bash
$ kubectl get pods -n litellm
NAME                       READY   STATUS             RESTARTS   AGE
litellm-7d8f9c5b4-x7k9m   0/1     CrashLoopBackOff   5          3m

$ kubectl logs litellm-7d8f9c5b4-x7k9m -n litellm
exec /usr/local/bin/python: exec format error
```

**根本原因**

在 macOS (ARM/Apple Silicon) 上构建的 Docker 镜像推送到 EKS Fargate (AMD64) 运行时,二进制格式不兼容。

**解决方案**

构建镜像时必须显式指定目标平台:

```bash
# 本地构建
docker build --platform linux/amd64 -t litellm:latest .

# 推送到 ECR
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin <account>.dkr.ecr.us-west-2.amazonaws.com
docker tag litellm:latest <account>.dkr.ecr.us-west-2.amazonaws.com/litellm:latest
docker push <account>.dkr.ecr.us-west-2.amazonaws.com/litellm:latest
```

**CI/CD 配置**

在 GitHub Actions 或其他 CI/CD 中使用 buildx:

```yaml
- name: Build and push
  uses: docker/build-push-action@v5
  with:
    platforms: linux/amd64
    push: true
    tags: ${{ env.ECR_REGISTRY }}/litellm:${{ github.sha }}
```

**经验教训**

始终在 CI/CD 中使用 `--platform linux/amd64`,即使本地是 ARM Mac。不要依赖默认平台配置。

---

## 2. 网络和负载均衡

### 2.1 WAF 关联 ALB 失败 - WAFUnavailableEntityException

**现象**

```bash
$ terraform apply
Error: operation error WAFv2: AssociateWebACL,
https response error StatusCode: 400, RequestID: xxx,
WAFUnavailableEntityException: The resource is not available for association.
```

**根本原因**

WAF 需要关联到完全就绪的 ALB,但 ALB 由 AWS Load Balancer Controller 异步创建。Terraform 创建 Ingress 后立即尝试关联 WAF 时,ALB 可能还在创建中。

**时间线**

1. Terraform 创建 Ingress 资源 (1-2秒)
2. ALB Controller 监听到 Ingress 事件 (2-5秒)
3. ALB Controller 开始创建 ALB (10-30秒)
4. ALB 完全就绪并接受流量 (30-60秒)

Terraform 在第1步后就尝试关联 WAF,此时 ALB 尚未创建。

**解决方案**

在 WAF 模块的 `null_resource` 中添加重试循环:

```hcl
resource "null_resource" "associate_waf" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "Waiting for ALB to be ready..."

      # 最多等待 5 分钟
      for i in $(seq 1 30); do
        echo "Attempt $i/30: Associating WAF with ALB..."

        if aws wafv2 associate-web-acl \
          --web-acl-arn ${aws_wafv2_web_acl.main.arn} \
          --resource-arn ${var.alb_arn} \
          --region ${var.region} 2>&1; then
          echo "WAF successfully associated"
          exit 0
        fi

        echo "ALB not ready yet, waiting 10 seconds..."
        sleep 10
      done

      echo "Failed to associate WAF after 5 minutes"
      exit 1
    EOT
  }
}
```

**验证 ALB 状态**

```bash
# 获取 ALB ARN
ALB_ARN=$(kubectl get ingress litellm-api -n litellm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' | \
  xargs -I {} aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='{}'].LoadBalancerArn" --output text)

# 检查 ALB 状态
aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].State.Code' --output text
# 输出应为: active

# 检查 WAF 关联
aws wafv2 list-resources-for-web-acl \
  --web-acl-arn <waf-arn> --resource-type APPLICATION_LOAD_BALANCER
```

**经验教训**

- ALB Ingress 是异步创建的,依赖它的资源必须有重试机制
- 不要假设 Terraform 的 `depends_on` 能处理异步资源
- 设置合理的超时时间 (5分钟) 和重试间隔 (10秒)

### 2.2 ALB 302 重定向循环

**现象**

```bash
$ curl -i https://litellm.example.com/v1/models
HTTP/2 302
location: https://auth.example.com/login?...
```

API 请求被重定向到 Cognito 登录页。

**根本原因**

存在两个 Ingress 共享同一个 ALB:
- `litellm-ui`: 路径 `/`, 优先级 50, 带 Cognito 认证
- `litellm-api`: 路径 `/chat/completions`, `/v1/*` 等, 优先级 10, 无认证

当 API 请求匹配到 UI Ingress 时,被强制进行 Cognito 认证。

**ALB 规则优先级**

ALB 规则按优先级数字从小到大匹配,数字越小越优先。

**排查步骤**

```bash
# 1. 检查 Ingress 优先级
kubectl get ingress -n litellm -o yaml | grep -A5 alb.ingress.kubernetes.io/group.order

# 2. 获取 ALB 控制台 URL
ALB_ARN=$(kubectl get ingress litellm-api -n litellm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' | \
  xargs -I {} aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='{}'].LoadBalancerArn" --output text)
echo "https://console.aws.amazon.com/ec2/home?region=us-west-2#LoadBalancers:search=$ALB_ARN"

# 3. 列出所有规则及优先级
aws elbv2 describe-rules --listener-arn <listener-arn> \
  --query 'Rules[].[Priority,Conditions[0].Values[0],Actions[0].Type]' \
  --output table
```

**解决方案**

确保 API Ingress 优先级更高 (数字更小):

```yaml
# litellm-api-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: litellm-api
  annotations:
    alb.ingress.kubernetes.io/group.order: "10"  # 优先匹配
    alb.ingress.kubernetes.io/auth-type: "none"  # 无认证
---
# litellm-ui-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: litellm-ui
  annotations:
    alb.ingress.kubernetes.io/group.order: "50"  # 较低优先级
    alb.ingress.kubernetes.io/auth-type: "cognito"
```

**最佳实践**

使用不同域名彻底避免此问题:
- API: `api.litellm.example.com`
- UI: `ui.litellm.example.com`

**经验教训**

共享 ALB 时,优先级配置至关重要。数字越小越优先,API 端点必须优先于 UI 路由。

---

## 3. 基础设施超时

### 3.1 Terraform Rollout 超时 ≠ 失败

**现象**

```bash
$ terraform apply
...
module.eks.kubernetes_deployment.litellm: Still creating... [5m0s elapsed]
Error: timeout while waiting for deployment rollout to complete
```

但实际 Pod 在正常启动中。

**根本原因**

LiteLLM 启动流程:
1. Fargate 分配计算资源并启动容器 (30-60秒)
2. 容器启动并初始化 (5-10秒)
3. 连接 PostgreSQL 数据库 (2-5秒)
4. 加载模型配置和验证 Bedrock 连接 (20-30秒)
5. 启动 FastAPI 服务器 (5-10秒)

总启动时间: 60-115秒,Terraform 默认超时 3 分钟。Fargate 冷启动比 EC2 节点慢,如果镜像较大可能超时。

**排查步骤**

```bash
# 1. 检查 Pod 状态
kubectl get pods -n litellm
# 状态为 Running 或 ContainerCreating 说明部署在进行中

# 2. 查看 Pod 事件
kubectl describe pod <pod-name> -n litellm
# 关注 Events 部分,查看镜像拉取、调度、健康检查

# 3. 实时查看启动日志
kubectl logs -f <pod-name> -n litellm
# 应看到 "Uvicorn running on http://0.0.0.0:4000"

# 4. 检查 Readiness Probe
kubectl get pod <pod-name> -n litellm -o jsonpath='{.status.conditions[?(@.type=="Ready")]}'
```

**解决方案**

增加 Terraform 超时:

```hcl
resource "kubernetes_deployment" "litellm" {
  # ...

  timeouts {
    create = "10m"
    update = "10m"
  }

  wait_for_rollout = true
}
```

或者禁用等待:

```hcl
resource "kubernetes_deployment" "litellm" {
  # ...
  wait_for_rollout = false
}
```

**验证部署成功**

```bash
# 等待所有 Pod Ready
kubectl wait --for=condition=Ready pod -l app=litellm -n litellm --timeout=300s

# 测试健康检查端点
kubectl port-forward -n litellm svc/litellm 4000:4000 &
curl http://localhost:4000/health
```

**经验教训**

- Terraform 超时只是超时,不代表实际部署失败
- 始终检查实际 Pod 状态和日志
- 设置合理的超时时间,考虑冷启动场景

---

## 4. Fargate 特有问题

### 5.1 Pod Pending 时间过长 - Fargate Profile 不匹配

**现象**

```bash
$ kubectl get pods -n litellm
NAME                       READY   STATUS    RESTARTS   AGE
litellm-7d8f9c5b4-x7k9m   0/1     Pending   0          3m

$ kubectl describe pod litellm-7d8f9c5b4-x7k9m -n litellm
Events:
  Warning  FailedScheduling  3m  fargate-scheduler
  No Fargate profile matched for pod
```

**根本原因**

Pod 的 namespace 或 labels 不匹配任何 Fargate Profile 选择器。

**排查步骤**

```bash
# 1. 检查 Fargate Profiles
aws eks list-fargate-profiles --cluster-name <cluster-name>

# 2. 查看 Profile 选择器
aws eks describe-fargate-profile \
  --cluster-name <cluster-name> \
  --fargate-profile-name <profile-name> \
  --query 'fargateProfile.selectors'

# 3. 检查 Pod labels 和 namespace
kubectl get pod <pod-name> -n litellm -o jsonpath='{.metadata.namespace},{.metadata.labels}'

# 4. 验证 Pod 是否在正确 namespace
kubectl get ns litellm
```

**解决方案**

1. **修改 Fargate Profile** (推荐):

```bash
# 在 Terraform 中添加 namespace
resource "aws_eks_fargate_profile" "litellm" {
  # ...
  selector {
    namespace = "litellm"
    labels = {
      app = "litellm"
    }
  }
}
```

2. **修改 Pod labels**:

```yaml
# deployment.yaml
metadata:
  labels:
    app: litellm  # 必须匹配 Fargate Profile 选择器
```

**经验教训**

- Fargate Profile 选择器不支持通配符,必须精确匹配
- 创建 namespace 后需要重新应用 Fargate Profile
- 系统组件 (如 coredns) 也需要独立的 Fargate Profile

### 5.2 CoreDNS 无法启动 - Fargate Profile 缺失

**现象**

```bash
$ kubectl get pods -n kube-system
NAME                      READY   STATUS    RESTARTS   AGE
coredns-xxx               0/1     Pending   0          10m

$ kubectl logs <pod-name> -n litellm
dial tcp: lookup litellm.example.com: no such host
```

**根本原因**

CoreDNS 默认部署在 EC2 节点上,Fargate 专属集群需要手动配置 CoreDNS 在 Fargate 运行。

**排查步骤**

```bash
# 1. 检查 CoreDNS Deployment 调度注解
kubectl get deployment coredns -n kube-system -o yaml | grep -A5 nodeSelector

# 2. 检查 Fargate Profile 是否包含 kube-system
aws eks describe-fargate-profile \
  --cluster-name <cluster-name> \
  --fargate-profile-name <profile-name> \
  --query 'fargateProfile.selectors[?namespace==`kube-system`]'
```

**解决方案**

1. **创建 kube-system Fargate Profile**:

```hcl
resource "aws_eks_fargate_profile" "kube_system" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "kube-system"
  pod_execution_role_arn = aws_iam_role.fargate_profile.arn
  subnet_ids             = var.private_subnets

  selector {
    namespace = "kube-system"
    labels = {
      k8s-app = "kube-dns"
    }
  }
}
```

2. **重启 CoreDNS**:

```bash
kubectl rollout restart deployment coredns -n kube-system
kubectl wait --for=condition=Ready pod -l k8s-app=kube-dns -n kube-system --timeout=120s
```

**经验教训**

- Fargate 专属集群必须为系统组件创建 Profile
- CoreDNS label 是 `k8s-app=kube-dns`,不是 `app=coredns`
- 部署顺序: Fargate Profile → 重启 CoreDNS → 部署应用

### 5.3 Fargate Pod 启动慢 - 冷启动延迟

**现象**

```bash
$ kubectl get pods -n litellm -w
NAME                       READY   STATUS    RESTARTS   AGE
litellm-7d8f9c5b4-x7k9m   0/1     Pending   0          0s
litellm-7d8f9c5b4-x7k9m   0/1     Pending   0          45s
litellm-7d8f9c5b4-x7k9m   0/1     ContainerCreating   0  50s
litellm-7d8f9c5b4-x7k9m   1/1     Running   0          90s
```

**根本原因**

Fargate 冷启动需要分配虚拟机资源,比 EC2 节点上的 Pod 启动慢 30-60 秒。

**优化策略**

1. **减小镜像大小**:

```dockerfile
# 使用多阶段构建
FROM python:3.11-slim as builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.11-slim
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY . .
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "4000"]
```

2. **增加 minReplicas** (保持热 Pod):

```yaml
# hpa.yaml
spec:
  minReplicas: 3  # 始终保持 3 个热 Pod
  maxReplicas: 10
```

3. **调整 Readiness Probe 延迟**:

```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 4000
  initialDelaySeconds: 60  # Fargate 冷启动需要更长时间
  periodSeconds: 10
```

**成本对比**

| 策略 | 启动时间 | 月成本增加 |
|-----|---------|----------|
| minReplicas=2 | 60-90秒 | $0 (基线) |
| minReplicas=5 | 60-90秒 | +$120/月 |
| 镜像优化 (500MB→150MB) | 40-60秒 | $0 |

**经验教训**

- Fargate 不适合对启动时间敏感的场景 (如 Serverless Functions)
- 镜像优化比增加副本数更经济
- 监控 Pod 启动时间指标,设置合理的 initialDelaySeconds

---

## 5. AWS 权限和服务

### 5.1 Bedrock 权限不足 - AccessDeniedException

**现象**

```bash
$ curl -X POST https://litellm.example.com/v1/chat/completions \
  -H "Authorization: Bearer sk-xxx" \
  -d '{"model":"opus","messages":[{"role":"user","content":"Hi"}]}'

{"error":{"message":"AccessDeniedException: User is not authorized to perform: bedrock:InvokeModel"}}
```

**根本原因**

IRSA（IAM Roles for Service Accounts）未正确配置,或 IAM 策略缺少必要权限。

**排查步骤**

```bash
# 1. 检查 Service Account 注解
kubectl get sa litellm-sa -n litellm -o yaml
# 应包含: eks.amazonaws.com/role-arn: arn:aws:iam::...

# 2. 检查 IAM Role 策略
ROLE_NAME=$(kubectl get sa litellm-sa -n litellm -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' | cut -d'/' -f2)
aws iam get-role-policy --role-name $ROLE_NAME --policy-name LiteLLMBedrockPolicy
# 确认包含 bedrock:InvokeModel, bedrock:InvokeModelWithResponseStream

# 3. 在 Pod 内验证凭证
kubectl exec -it <pod> -n litellm -- sh
env | grep AWS_
# 应显示 AWS_CONTAINER_CREDENTIALS_FULL_URI, AWS_ROLE_ARN

# 4. 测试 Bedrock 调用
kubectl exec -it <pod> -n litellm -- python3 -c "
import boto3
client = boto3.client('bedrock-runtime', region_name='us-west-2')
response = client.list_foundation_models()
print(response)
"
```

**常见问题**

**问题 1**: Service Account 缺少注解

```bash
kubectl annotate sa litellm-sa -n litellm \
  eks.amazonaws.com/role-arn=arn:aws:iam::123456789012:role/LiteLLMBedrockRole
```

**问题 2**: Trust Policy 不正确（IRSA 使用 OIDC provider）

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.us-west-2.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:sub": "system:serviceaccount:litellm:litellm-sa"
      }
    }
  }]
}
```

**问题 3**: 权限策略范围过窄

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:ListFoundationModels",
      "bedrock:GetFoundationModel"
    ],
    "Resource": "*"
  }]
}
```

**经验教训**

IRSA 配置涉及多个组件,逐步验证每个环节:
1. Service Account 有 `eks.amazonaws.com/role-arn` 注解
2. IAM Role Trust Policy 正确（使用 OIDC provider + `sts:AssumeRoleWithWebIdentity`）
3. IAM Role 权限策略完整
4. Pod 内凭证正确注入

### 5.2 Bedrock 模型不可用

**现象**

```bash
{"error":{"message":"ValidationException: The provided model identifier is invalid"}}
```

**排查**

```bash
# 检查区域内可用模型
aws bedrock list-foundation-models --region us-west-2 \
  --query 'modelSummaries[?modelLifecycle.status==`ACTIVE`].[modelId,modelName]' \
  --output table

# 检查模型访问权限
aws bedrock get-foundation-model-availability \
  --model-identifier anthropic.claude-opus-4-6-v1 \
  --region us-west-2
```

---

## 6. 配置和更新

### 6.1 ConfigMap 更新后 Pod 未生效

**现象**

修改 `config.yaml` 并更新 ConfigMap,但 Pod 仍使用旧配置。

**根本原因**

Kubernetes 不会自动重启使用 ConfigMap 的 Pod。Pod 在启动时读取 ConfigMap,后续不会重新加载。

**解决方案**

**方法 1**: 手动重启 Deployment

```bash
kubectl rollout restart deployment litellm -n litellm
kubectl rollout status deployment litellm -n litellm
```

**方法 2**: 添加 Annotation 触发更新

```bash
kubectl patch deployment litellm -n litellm \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config-hash\":\"$(date +%s)\"}}}}}"
```

**方法 3**: 使用 Reloader (推荐)

安装 Stakater Reloader:

```bash
kubectl apply -f https://raw.githubusercontent.com/stakater/Reloader/master/deployments/kubernetes/reloader.yaml
```

在 Deployment 中添加注解:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  annotations:
    reloader.stakater.com/auto: "true"  # 自动监听 ConfigMap 和 Secret
spec:
  template:
    spec:
      containers:
      - name: litellm
        volumeMounts:
        - name: config
          mountPath: /app/config.yaml
          subPath: config.yaml
      volumes:
      - name: config
        configMap:
          name: litellm-config
```

**验证配置生效**

```bash
# 进入 Pod 检查配置文件
kubectl exec -it <pod> -n litellm -- cat /app/config.yaml

# 检查环境变量
kubectl exec -it <pod> -n litellm -- env | grep LITELLM
```

---

## 7. 脚本兼容性

### 7.1 macOS head -n 负数不兼容

**现象**

```bash
$ ./test-api.sh
head: illegal line count -- -1
```

**根本原因**

macOS 使用 BSD 版本的 `head`,不支持 `head -n -1` (负数行数) 语法。GNU coreutils 支持此语法。

**BSD vs GNU 差异**

```bash
# GNU (Linux): 输出除最后 N 行外的所有行
head -n -1 file.txt

# BSD (macOS): 不支持负数,需要其他方式
```

**解决方案**

**方法 1**: 使用 `sed` 删除最后一行

```bash
# 替换
BODY=$(curl -s -w "\n%{http_code}" "$URL" | head -n -1)

# 为
BODY=$(curl -s -w "\n%{http_code}" "$URL" | sed '$d')
```

**方法 2**: 分离 HTTP status code

```bash
HTTP_CODE=$(curl -s -o /tmp/response.json -w "%{http_code}" "$URL")
BODY=$(cat /tmp/response.json)
```

**方法 3**: 安装 GNU coreutils (macOS)

```bash
brew install coreutils
# 使用 ghead 代替 head
BODY=$(curl -s -w "\n%{http_code}" "$URL" | ghead -n -1)
```

**经验教训**

编写跨平台脚本时:
- 避免使用 BSD/GNU 不一致的语法
- 优先使用 POSIX 标准命令
- 在文档中说明平台要求
- 使用 shellcheck 检查兼容性

---

## 8. 常用调试命令

### 8.1 Pod 状态和日志

```bash
# 列出所有 Pod
kubectl get pods -n litellm

# 查看 Pod 详情和事件
kubectl describe pod <pod-name> -n litellm

# 实时查看日志
kubectl logs -f <pod-name> -n litellm

# 查看前一个崩溃的容器日志
kubectl logs <pod-name> -n litellm --previous

# 按标签查看所有 Pod 日志
kubectl logs -l app=litellm -n litellm --tail=100

# 进入 Pod 调试
kubectl exec -it <pod-name> -n litellm -- sh

# 端口转发到本地
kubectl port-forward -n litellm svc/litellm 4000:4000
```

### 8.2 Service 和 Ingress

```bash
# 查看 Service
kubectl get svc -n litellm
kubectl describe svc litellm -n litellm

# 查看 Ingress
kubectl get ingress -n litellm
kubectl describe ingress litellm-api -n litellm

# 获取 ALB DNS
kubectl get ingress litellm-api -n litellm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# 查看 Ingress 事件
kubectl get events -n litellm --field-selector involvedObject.kind=Ingress
```

### 8.3 ALB 状态 (AWS CLI)

```bash
# 列出所有 ALB
aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerName,DNSName,State.Code]' --output table

# 获取 ALB ARN (通过 Ingress)
ALB_DNS=$(kubectl get ingress litellm-api -n litellm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
ALB_ARN=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$ALB_DNS'].LoadBalancerArn" --output text)

# 查看 ALB 监听器
aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN

# 查看目标组健康状态
aws elbv2 describe-target-health --target-group-arn <target-group-arn>

# 查看 ALB 规则
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query 'Listeners[0].ListenerArn' --output text)
aws elbv2 describe-rules --listener-arn $LISTENER_ARN \
  --query 'Rules[].[Priority,Conditions[0].Values[0],Actions[0].Type]' \
  --output table
```

### 8.4 Bedrock 可用性检查

```bash
# 列出可用模型
aws bedrock list-foundation-models --region us-west-2 \
  --query 'modelSummaries[?modelLifecycle.status==`ACTIVE`].[modelId,modelName]' \
  --output table

# 检查特定模型
aws bedrock get-foundation-model \
  --model-identifier anthropic.claude-opus-4-6-v1 \
  --region us-west-2

# 测试调用 (需要 base64 编码)
aws bedrock-runtime invoke-model \
  --model-id anthropic.claude-opus-4-6-v1 \
  --body '{"anthropic_version":"bedrock-2023-05-31","messages":[{"role":"user","content":"Hi"}],"max_tokens":100}' \
  --region us-west-2 \
  /tmp/response.json
cat /tmp/response.json | jq
```

### 8.5 ECR 镜像管理

```bash
# 列出 ECR 仓库
aws ecr describe-repositories --region us-west-2

# 列出镜像标签
REPO_NAME=$(terraform output -raw ecr_repository_name)
aws ecr list-images --repository-name $REPO_NAME --region us-west-2

# 查看镜像详情
aws ecr describe-images \
  --repository-name $REPO_NAME \
  --image-ids imageTag=latest \
  --region us-west-2

# 测试镜像拉取 (从 Pod 内)
kubectl exec -it <pod> -n litellm -- sh
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin <account>.dkr.ecr.us-west-2.amazonaws.com
docker pull <account>.dkr.ecr.us-west-2.amazonaws.com/$REPO_NAME:latest
```

### 8.6 Fargate 和 EKS 集群状态

```bash
# 集群信息
aws eks describe-cluster --name litellm-prod \
  --query 'cluster.{Status:status,Version:version,Endpoint:endpoint}' \
  --output table

# Fargate Profiles
aws eks list-fargate-profiles --cluster-name litellm-prod

# 查看 Fargate Profile 详情
aws eks describe-fargate-profile \
  --cluster-name litellm-prod \
  --fargate-profile-name <profile-name>

# Pod 调度到 Fargate 验证
kubectl get pods -n litellm -o wide
# 注意 NODE 列会显示 fargate-xxx

# 查看 Fargate Pod 资源
kubectl describe node <fargate-node-name>

# Pod 资源使用
kubectl top pods -n litellm

# 查看集群事件
kubectl get events -n litellm --sort-by='.lastTimestamp'

# 查看 IRSA 配置
kubectl get sa litellm -n litellm -o yaml
# 确认 annotations 包含 eks.amazonaws.com/role-arn
```

### 8.7 ConfigMap 和 Secret

```bash
# 查看 ConfigMap
kubectl get configmap litellm-config -n litellm -o yaml

# 查看特定键
kubectl get configmap litellm-config -n litellm -o jsonpath='{.data.config\.yaml}'

# 查看 Secret (base64 解码)
kubectl get secret litellm-secret -n litellm -o jsonpath='{.data.DATABASE_URL}' | base64 -d

# 更新 ConfigMap
kubectl create configmap litellm-config -n litellm \
  --from-file=config.yaml --dry-run=client -o yaml | kubectl apply -f -

# 触发 Pod 重启
kubectl rollout restart deployment litellm -n litellm
```

### 8.8 健康检查和可用性

```bash
# 本地测试 (通过 port-forward)
kubectl port-forward -n litellm svc/litellm 4000:4000 &
curl http://localhost:4000/health
curl http://localhost:4000/v1/models

# 远程测试 (通过 ALB)
ALB_DNS=$(kubectl get ingress litellm-api -n litellm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -k https://$ALB_DNS/health
curl -k https://$ALB_DNS/v1/models -H "Authorization: Bearer sk-xxx"

# 流式测试
curl -X POST https://$ALB_DNS/v1/chat/completions \
  -H "Authorization: Bearer sk-xxx" \
  -H "Content-Type: application/json" \
  -d '{"model":"opus","messages":[{"role":"user","content":"Count to 5"}],"stream":true}'
```

### 8.9 Terraform 状态

```bash
# 查看 Terraform 输出
cd terraform
terraform output

# 查看特定资源状态
terraform state show module.eks.aws_eks_cluster.main

# 刷新状态
terraform refresh

# 查看计划 (不应用)
terraform plan

# 查看资源依赖图
terraform graph | dot -Tpng > graph.png
```

---

## 快速诊断流程

遇到问题时,按以下顺序排查:

1. **Pod 状态**: `kubectl get pods -n litellm` - Pod 是否 Running? 是否在 Fargate 节点上?
2. **Fargate Profile**: `aws eks list-fargate-profiles` - Profile 是否匹配 Pod namespace/labels?
3. **Pod 日志**: `kubectl logs <pod> -n litellm` - 启动错误?
4. **Pod 事件**: `kubectl describe pod <pod> -n litellm` - 镜像拉取失败? 调度失败?
5. **Service 可达性**: `kubectl port-forward -n litellm svc/litellm 4000:4000` + `curl localhost:4000/health`
6. **数据库连接**: 检查 Pod 日志中 PostgreSQL 连接是否成功
7. **Ingress 状态**: `kubectl get ingress -n litellm` - ALB 已创建?
8. **ALB 健康检查**: AWS 控制台查看 Target Group 健康状态
9. **权限验证**: 在 Pod 内运行 `env | grep AWS` 和检查 IRSA ServiceAccount 注解

---

## 附录: 常见错误码速查

| 错误 | 原因 | 解决方向 |
|------|------|----------|
| CrashLoopBackOff | 容器启动失败 | 检查日志,镜像平台 (amd64),配置 |
| ImagePullBackOff | 镜像拉取失败 | ECR 权限,镜像名称,Fargate 执行角色 |
| Pending (无 Fargate 节点) | Fargate Profile 不匹配 | 检查 Profile 选择器,namespace,labels |
| Pending (长时间) | Fargate 冷启动慢 | 正常现象 (30-60秒),优化镜像大小 |
| 0/1 Running | 健康检查失败 | 检查 Readiness Probe,Fargate 启动延迟 |
| 502 Bad Gateway | ALB → Pod 连接失败 | Target Group 健康检查,SG 规则 |
| 504 Gateway Timeout | 后端响应超时 | Pod 性能,超时配置,Fargate 资源 |
| 403 Forbidden | 权限不足 | IAM 策略,IRSA 配置,Bedrock 权限 |
| Invalid API Key | Key 不存在或过期 | 检查 LiteLLM Admin UI,PostgreSQL 数据库 |

---

## 联系和资源

- **项目仓库**: [serverless-litellm](https://github.com/cncoder/serverless-litellm)
- **LiteLLM 文档**: https://docs.litellm.ai
- **AWS EKS 文档**: https://docs.aws.amazon.com/eks/
- **Troubleshooting 更新**: 欢迎提交 PR 补充实际问题

**最后更新**: 2026-02-25
