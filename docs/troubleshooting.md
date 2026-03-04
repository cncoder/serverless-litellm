# 故障排查

## 常见问题

### Pod 启动失败 - CrashLoopBackOff

```bash
# 查看日志
kubectl logs -n litellm -l app=litellm --tail=100

# 查看 Secret
kubectl get secret litellm-secrets -n litellm -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d
```

常见原因：配置文件语法错误、Master Key 格式问题（必须以 `sk-` 开头）。

### Ingress 无外部 IP

```bash
# 检查 ALB Controller 日志
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50

# 检查 Ingress 状态
kubectl describe ingress -n litellm
```

常见原因：IRSA（IAM Roles for Service Accounts）绑定未生效（需等待 1-2 分钟），或 IAM 权限不足。

### 502 Bad Gateway

```bash
# 检查 Pod 和 Endpoints
kubectl get pods -n litellm
kubectl get endpoints litellm -n litellm

# 检查 ALB Target Group 健康检查
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName, 'litellmshared')].LoadBalancerArn" \
  --output text)
TG_ARN=$(aws elbv2 describe-target-groups \
  --load-balancer-arn $ALB_ARN \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)
aws elbv2 describe-target-health --target-group-arn $TG_ARN
```

### Bedrock 调用失败

```bash
# 查看 Bedrock 相关日志
kubectl logs -n litellm -l app=litellm | grep -i bedrock

# 检查 IRSA 绑定
kubectl describe sa litellm-sa -n litellm

# 确认 Bedrock 模型已在目标区域开启
aws bedrock list-foundation-models --region us-west-2 | jq '.modelSummaries[].modelId'
```

### Fargate Pod 资源不足

Fargate 要求 `requests == limits`。检查 `kubernetes/deployment.yaml` 中的资源配置：

```yaml
resources:
  requests:
    cpu: "1"
    memory: "2Gi"
  limits:
    cpu: "1"      # 必须等于 requests
    memory: "2Gi" # 必须等于 requests
```

---

## 调试命令集合

```bash
# 查看所有资源
kubectl get all -n litellm

# 实时日志
kubectl logs -n litellm -l app=litellm --tail=50 -f

# 进入容器
kubectl exec -it -n litellm deployment/litellm -- sh

# 测试 Service 连通性（集群内部）
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://litellm.litellm.svc.cluster.local/health/liveliness

# 查看事件
kubectl get events -n litellm --sort-by='.lastTimestamp'
kubectl get events -n kube-system --sort-by='.lastTimestamp' | grep -i alb

# ALB Controller 日志
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100

# 查看 HPA 状态
kubectl get hpa -n litellm

# 查看 PDB
kubectl get pdb -n litellm
```

---

## Master Key 找回

Master Key 存储在 AWS Secrets Manager，任何时候都可以找回：

```bash
aws secretsmanager get-secret-value \
  --secret-id litellm-master-key-prod \
  --region us-west-2 \
  --query SecretString \
  --output text
```

---

## 清理资源

**完全删除所有资源**:

```bash
# 删除
cd terraform
terraform destroy
```

**警告**: 此操作将删除 EKS 集群、RDS 数据库（API Keys 数据）、VPC、ALB、ECR 等全部资源。

**仅删除 Kubernetes 资源**:

```bash
kubectl delete -k kubernetes/
```
