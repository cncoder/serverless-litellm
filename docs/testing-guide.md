# LiteLLM on EKS 测试指南

本文档提供了全面的测试方法，用于验证 LiteLLM 部署的功能、性能、高可用性和安全性。

## 1. 功能测试

### 1.1 test-models.sh 使用方法

自动化测试脚本支持快速验证所有模型可用性。

```bash
# 基本用法
./scripts/test-models.sh https://litellm.example.com sk-your-api-key

# 测试特定模型
./scripts/test-models.sh https://litellm.example.com sk-your-api-key claude-opus-4-6-us
```

**输出示例**:
```
[1/9] claude-opus-4-6-us
  EN  [OK]   2.35s  I am Claude, made by Anthropic...
  ZH  [OK]   1.89s  我是 Claude，由 Anthropic 开发...

[2/9] claude-sonnet-4-6-us
  EN  [OK]   1.42s  Hello! I'm Claude...
  ZH  [OK]   1.38s  你好！我是 Claude...

Summary: 18/18 passed
```

该脚本验证：
- 所有 9 个模型的可用性
- 英文和中文提示的响应质量
- 响应时间（正常范围 1-5 秒）
- 适合部署后快速验证

### 1.2 单模型快速测试

使用 curl 直接测试单个模型。

```bash
# 基础 completion 测试
curl -s https://litellm.example.com/chat/completions \
  -H "Authorization: Bearer <YOUR_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-haiku-4-5",
    "messages": [{"role": "user", "content": "Hi"}],
    "max_tokens": 50
  }'

# 流式响应测试
curl -N https://litellm.example.com/chat/completions \
  -H "Authorization: Bearer <YOUR_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-6-us",
    "messages": [{"role": "user", "content": "Count to 10"}],
    "stream": true
  }'
```

### 1.3 健康检查端点

```bash
# 存活检查 (Liveness)
curl https://litellm.example.com/health/liveliness
# 期望: {"status": "healthy"}

# 就绪检查 (Readiness) - 包含数据库连接状态
curl https://litellm.example.com/health/readiness
# 期望: {"status": "healthy", "db": "connected"}

# 模型列表
curl https://litellm.example.com/v1/models \
  -H "Authorization: Bearer <YOUR_API_KEY>"
# 期望: 返回 9 个模型的列表
```

### 1.4 降级链测试 (Fallback)

验证模型故障时自动降级到备用模型。

**测试步骤**:
1. 在 `config.yaml` 中配置主模型和降级链
2. 模拟主模型不可用（例如临时修改模型 ID 为无效值）
3. 发送请求并观察日志

```bash
# 监控日志查看降级行为
kubectl logs -f deployment/litellm -n litellm | grep -i fallback

# 示例日志输出
# [INFO] Primary model claude-opus-4-6-us failed: ThrottlingException
# [INFO] Falling back to claude-sonnet-4-6-us
# [INFO] Fallback successful, response returned
```

**验证要点**:
- 请求最终返回成功（200 OK）
- 日志显示降级触发
- 响应来自备用模型

### 1.5 多轮对话测试

```bash
curl -s https://litellm.example.com/chat/completions \
  -H "Authorization: Bearer <YOUR_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-6-us",
    "messages": [
      {"role": "user", "content": "My name is Alice"},
      {"role": "assistant", "content": "Nice to meet you, Alice!"},
      {"role": "user", "content": "What is my name?"}
    ]
  }'
# 期望: 返回 "Alice"
```

## 2. 高可用测试

### 2.1 Pod 故障恢复

验证单个 Pod 故障时服务不中断。

```bash
# 查看当前 Pod
kubectl get pods -n litellm

# 删除一个 Pod 模拟故障
kubectl delete pod <pod-name> -n litellm

# 观察自动重建
kubectl get pods -n litellm -w
```

**并发测试不中断**:
```bash
# 在另一个终端持续发送请求
while true; do
  response=$(curl -s -o /dev/null -w "%{http_code}" \
    https://litellm.example.com/health/liveliness)
  echo "$(date '+%H:%M:%S') - $response"
  sleep 0.5
done
```

期望结果：
- Pod 在 10-30 秒内自动重建
- 请求持续返回 200，无 5xx 错误
- 证明多副本配置有效

### 2.2 滚动更新零停机

验证配置更新时服务不中断。

```bash
# 触发配置更新
kubectl apply -f kubernetes/configmap.yaml
kubectl rollout restart deployment litellm -n litellm

# 监控更新过程
kubectl rollout status deployment litellm -n litellm
# 输出: deployment "litellm" successfully rolled out

# 验证更新策略
kubectl describe deployment litellm -n litellm | grep -A 3 "RollingUpdateStrategy"
# 期望: maxSurge: 1, maxUnavailable: 0
```

**持续流量测试**:
```bash
# 使用 hey 或 ab 工具发送持续流量
hey -z 5m -c 10 -H "Authorization: Bearer <KEY>" \
  -m POST -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5","messages":[{"role":"user","content":"Hi"}]}' \
  https://litellm.example.com/chat/completions

# 观察错误率应为 0%
```

### 2.3 HPA 自动扩缩容

验证负载增加时自动扩展 Pod 数量。

```bash
# 查看当前 HPA 状态
kubectl get hpa litellm-hpa -n litellm
# 输出: NAME          REFERENCE            TARGETS   MINPODS   MAXPODS   REPLICAS
#       litellm-hpa   Deployment/litellm   15%/70%   3         10        3

# 发送大量请求触发扩容
./scripts/benchmark.sh 50 1000 claude-haiku-4-5

# 实时监控 Pod 数量变化
kubectl get pods -n litellm -w
```

**观察要点**:
- CPU 使用率超过 70% 时触发扩容
- Pod 数量在 3-10 之间动态调整
- 扩容延迟约 30-60 秒
- 负载降低后缩容（约 5 分钟后）

### 2.4 跨可用区容错

```bash
# 查看 Pod 分布在不同 AZ
kubectl get pods -n litellm -o wide

# 验证 Pod 均匀分布
kubectl get pods -n litellm -o json | \
  jq -r '.items[] | .spec.nodeName' | \
  xargs -I {} kubectl get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}'
# 期望: 输出多个不同的 us-west-2a, us-west-2b, us-west-2c
```

## 3. 性能测试

### 3.1 benchmark.sh 使用方法

压力测试脚本用于评估吞吐量和延迟。

```bash
# 用法: ./scripts/benchmark.sh [并发数] [总请求数] [模型名]

# 轻负载测试
LITELLM_URL=https://litellm.example.com \
LITELLM_MASTER_KEY=sk-xxx \
./scripts/benchmark.sh 5 50 claude-haiku-4-5

# 中等负载测试
./scripts/benchmark.sh 20 200 claude-sonnet-4-6-us

# 高负载测试
./scripts/benchmark.sh 50 500 claude-haiku-4-5
```

### 3.2 关键指标解读

**延迟指标** (Latency):
- **平均延迟**: Claude Haiku 1-3s, Sonnet 2-5s, Opus 3-8s
- **P95 延迟**: 应 < 10s
- **P99 延迟**: 应 < 20s，超过 30s 检查 Bedrock 限流或网络

**吞吐量** (Throughput):
- **req/s**: 受 Bedrock 配额限制，典型值 10-50 req/s
- **tokens/s**: 取决于模型，Haiku 最快，Opus 较慢

**错误率**:
- 应 < 1%
- 高错误率检查：Bedrock 配额、API Key 权限、网络问题

### 3.3 Bedrock 限流处理

Bedrock 限流类型：
- **TPM (Tokens Per Minute)**: 每分钟处理 token 数
- **RPM (Requests Per Minute)**: 每分钟请求数
- **Cross-Region Inference Profiles**: 提供更高配额

**监控限流**:
```bash
# 查看日志中的限流错误
kubectl logs deployment/litellm -n litellm | grep -i throttling

# 示例输出
# ThrottlingException: Rate exceeded for model claude-opus-4-6
```

**缓解策略**:
1. 配置降级链分散流量
2. 使用 cross-region profiles (`-us` 后缀)
3. 调整并发数和请求速率
4. 申请配额提升

## 4. 安全测试

### 4.1 API Key 验证

```bash
# 无 Key 应返回 401
curl -i https://litellm.example.com/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5","messages":[{"role":"user","content":"Hi"}]}'
# 期望: HTTP/1.1 401 Unauthorized

# 错误 Key 应返回 401
curl -i https://litellm.example.com/chat/completions \
  -H "Authorization: Bearer sk-invalid-key-12345" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5","messages":[{"role":"user","content":"Hi"}]}'
# 期望: HTTP/1.1 401 Unauthorized

# 正确 Key 应返回 200
curl -i https://litellm.example.com/chat/completions \
  -H "Authorization: Bearer <VALID_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5","messages":[{"role":"user","content":"Hi"}],"max_tokens":10}'
# 期望: HTTP/1.1 200 OK
```

### 4.2 WAF 速率限制测试

如果启用了 AWS WAF，验证速率限制规则。

```bash
# 快速发送超过限制的请求 (默认 2000/5min)
for i in $(seq 1 2100); do
  response=$(curl -s -o /dev/null -w "%{http_code}" \
    https://litellm.example.com/health/liveliness)
  echo "Request $i: $response"
  [ "$response" = "403" ] && echo "Rate limit triggered at request $i" && break
done
```

期望结果：
- 前 2000 个请求返回 200
- 超过限制后返回 403
- 5 分钟后恢复正常

### 4.3 HTTPS/TLS 验证

```bash
# 验证 TLS 证书有效
curl -vI https://litellm.example.com 2>&1 | grep -i "SSL certificate verify"
# 期望: SSL certificate verify ok

# 验证强制 HTTPS (HTTP 重定向)
curl -I http://litellm.example.com
# 期望: HTTP/1.1 301 Moved Permanently
# Location: https://litellm.example.com

# 检查证书过期时间
echo | openssl s_client -servername litellm.example.com -connect litellm.example.com:443 2>/dev/null | \
  openssl x509 -noout -dates
```

### 4.4 Cognito 认证测试 (可选)

如果启用了 Cognito 认证。

```bash
# 访问 UI 域应重定向到 Cognito 登录
curl -I https://litellm-ui.example.com
# 期望: HTTP/1.1 302 Found
# Location: https://<cognito-domain>.auth.us-west-2.amazoncognito.com/login

# API 域不应重定向 (直接使用 API Key)
curl -I https://litellm.example.com/health/liveliness
# 期望: HTTP/1.1 200 OK (无重定向)
```

## 5. 数据库测试

### 5.1 RDS 连接验证

```bash
# 查看 Pod 日志确认数据库连接
kubectl logs deployment/litellm -n litellm | grep -i database
# 期望: Database connected successfully

# 测试 readiness 端点 (包含 DB 检查)
curl https://litellm.example.com/health/readiness
# 期望: {"status": "healthy", "db": "connected"}
```

### 5.2 数据持久化验证

```bash
# 创建测试 API Key
kubectl exec -it deployment/litellm -n litellm -- litellm create_key --alias test-key

# 重启 Pod
kubectl rollout restart deployment litellm -n litellm

# 验证 Key 仍然有效
curl https://litellm.example.com/v1/models \
  -H "Authorization: Bearer <test-key>"
# 期望: 返回模型列表，证明数据未丢失
```

## 6. 测试检查清单

| 类别 | 测试项 | 预期结果 | 状态 |
|------|--------|---------|------|
| **健康检查** | GET /health/liveliness | 200 OK | ☐ |
| **健康检查** | GET /health/readiness | 200 OK + DB connected | ☐ |
| **模型** | claude-opus-4-6-us | 200 + 响应 | ☐ |
| **模型** | claude-sonnet-4-6-us | 200 + 响应 | ☐ |
| **模型** | claude-haiku-4-5 | 200 + 响应 | ☐ |
| **模型** | 所有 9 个模型 | test-models.sh 全部通过 | ☐ |
| **降级** | 主模型不可用 | 自动降级到备用模型 | ☐ |
| **高可用** | 删除 1 个 Pod | 10-30s 内自动恢复 | ☐ |
| **高可用** | 滚动更新 | 零停机，无 5xx | ☐ |
| **高可用** | HPA 扩容 | 高负载时 Pod 增加 | ☐ |
| **高可用** | HPA 缩容 | 低负载时 Pod 减少 | ☐ |
| **性能** | 平均延迟 | < 5s (Haiku/Sonnet) | ☐ |
| **性能** | P99 延迟 | < 20s | ☐ |
| **性能** | 错误率 | < 1% | ☐ |
| **安全** | 无 API Key | 401 Unauthorized | ☐ |
| **安全** | 错误 API Key | 401 Unauthorized | ☐ |
| **安全** | WAF 速率限制 | 超限后 403 | ☐ |
| **安全** | HTTPS 证书 | 有效证书 | ☐ |
| **数据库** | Readiness 检查 | DB connected | ☐ |
| **数据库** | 数据持久化 | 重启后数据保留 | ☐ |

## 7. 故障排查

### 7.1 常见问题

**问题**: 请求返回 401 Unauthorized
- 检查 API Key 是否正确
- 验证 Header 格式：`Authorization: Bearer sk-xxx`
- 确认 Key 未过期或被删除

**问题**: 请求超时或延迟高
- 检查 Bedrock 限流：`kubectl logs deployment/litellm -n litellm | grep Throttling`
- 验证 Pod CPU/内存使用：`kubectl top pods -n litellm`
- 增加 Pod 副本数或调整 HPA 阈值

**问题**: 健康检查失败
- 检查数据库连接：`kubectl logs deployment/litellm -n litellm | grep database`
- 验证 RDS 安全组允许 EKS 访问
- 确认环境变量配置正确

**问题**: 模型不可用
- 验证 IAM 角色权限
- 检查 AWS 区域配置 (us-west-2)
- 确认模型 ID 正确 (含 `-us` 后缀)

### 7.2 日志查看

```bash
# 实时查看所有 Pod 日志
kubectl logs -f deployment/litellm -n litellm --all-containers=true

# 查看特定 Pod 日志
kubectl logs <pod-name> -n litellm

# 查看最近 100 行日志
kubectl logs deployment/litellm -n litellm --tail=100

# 过滤错误日志
kubectl logs deployment/litellm -n litellm | grep -i error
```

### 7.3 监控指标

```bash
# 查看 Pod 资源使用
kubectl top pods -n litellm

# 查看 HPA 状态
kubectl describe hpa litellm-hpa -n litellm

# 查看 Service 端点
kubectl get endpoints litellm-service -n litellm
```

## 8. 持续监控

### 8.1 建议监控指标

- **请求成功率**: > 99%
- **平均延迟**: < 5s
- **P99 延迟**: < 20s
- **Pod CPU 使用率**: < 70%
- **Pod 内存使用率**: < 80%
- **数据库连接**: Healthy
- **Bedrock 限流次数**: 监控并优化

### 8.2 告警配置

建议配置以下告警：
- 错误率 > 5% 持续 5 分钟
- P99 延迟 > 30s 持续 5 分钟
- Pod 重启次数 > 3 次/小时
- 数据库连接失败
- HPA 达到最大副本数

## 9. 测试环境 vs 生产环境

| 项目 | 测试环境 | 生产环境 |
|------|---------|---------|
| 最小 Pod 数 | 2 | 3 |
| 最大 Pod 数 | 5 | 10 |
| 数据库实例 | db.t3.small | db.t3.medium |
| WAF | 可选 | 推荐启用 |
| Cognito | 可选 | 按需启用 |
| 监控告警 | 基础 | 全面 |

测试环境可以降低配置以节约成本，生产环境应保持文档推荐配置。
