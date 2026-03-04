# Amazon Bedrock 监控与成本管控指南

> **适用模型**：Claude 4.5 / 4.6（Opus、Sonnet、Haiku）
> **适用模式**：Cross-Region Inference / Global Cross-Region Inference（On-Demand）
> **验证区域**：us-west-2（2026-03-04 实测）

---

## 指标速查表

| 指标/数据 | 在哪看 | 怎么看 | 意义 | 文档 |
|-----------|--------|--------|------|------|
| **`InvocationThrottles`** | CloudWatch → AWS/Bedrock | Sum/1min，设 ≥1 告警 | 429 限流次数，**最核心指标** | [Runtime metrics](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring.html) |
| **`InvocationClientErrors`** | CloudWatch → AWS/Bedrock | Sum/1min | 所有 4xx 错误（含 429），辅助判断 | [同上](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring.html) |
| **`InvocationServerErrors`** | CloudWatch → AWS/Bedrock | Sum/1min | 5xx 服务端错误 | [同上](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring.html) |
| **`Invocations`** | CloudWatch → AWS/Bedrock | Sum/1min = RPM | 成功调用数 | [同上](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring.html) |
| **`InputTokenCount`** | CloudWatch → AWS/Bedrock | Sum/1min | 输入 Token | [同上](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring.html) |
| **`OutputTokenCount`** | CloudWatch → AWS/Bedrock | Sum/1min，×5 burndown | 输出 Token，Claude 3.7+ 按 5 倍扣 TPM | [Token Burndown](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas-token-burndown.html) |
| **`InvocationLatency`** | CloudWatch → AWS/Bedrock | Avg, p50, p99 | 端到端延迟 | [Runtime metrics](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring.html) |
| **`TimeToFirstToken`** | CloudWatch → AWS/Bedrock | Avg, p50, p99 | 首 Token 延迟（流式响应体验） | [Runtime metrics](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring.html) |
| **`EstimatedTPMQuotaUsage`** | CloudWatch → AWS/Bedrock | Max/1min | TPM 配额使用量估算，可直接设告警 | [Runtime metrics](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring.html) |
| **`CacheReadInputTokenCount`** | CloudWatch → AWS/Bedrock | Sum/1min | Cache 命中量 | [Prompt Caching](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html) |
| **`CacheWriteInputTokenCount`** | CloudWatch → AWS/Bedrock | Sum/1min | Cache 写入量 | [同上](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html) |
| **TPM / RPM 配额** | Service Quotas API / 控制台 | `list-service-quotas --service-code bedrock` | 账户限额上限 | [Quotas](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas.html) |
| **TPM/RPM 使用率 %** | Service Quotas → 创建告警 | 原生支持百分比告警 | 429 **前**预警，推荐 70%+90% | [同上](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas.html) |
| **每日费用** | Cost Explorer | 按 USAGE_TYPE 分组 | 成本趋势（延迟 ~24h） | — |
| **调用详情日志** | Invocation Logging → S3/CW Logs | Athena 或 Logs Insights | 请求级明细 | [Invocation Logging](https://docs.aws.amazon.com/bedrock/latest/userguide/model-invocation-logging.html) |

> **快速上手**：① CloudWatch 设 `InvocationThrottles ≥ 1` 告警 → ② Service Quotas 设 TPM 70% 使用率告警。两步覆盖最关键的限流预防。

> **注意**：`TimeToFirstToken` 和 `EstimatedTPMQuotaUsage` 需有实际调用数据后才会出现在 CloudWatch 中。

---

## 一、推理模式与配额

### 1.1 三种模式

| 模式 | ModelId 格式 | 示例 |
|------|-------------|------|
| On-Demand | `{provider}.{model}` | `anthropic.claude-sonnet-4-6` |
| Cross-Region | `{prefix}.{provider}.{model}` | `us.anthropic.claude-opus-4-6-v1` |
| Global Cross-Region | `global.{provider}.{model}` | `global.anthropic.claude-opus-4-6-v1` |

> Claude 4.x **无 Regional On-Demand 配额**，必须通过 Cross-Region 或 Global Cross-Region Inference 使用。完整 Profile 列表见 [Inference Profiles](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-support.html)，路由机制见 [Cross-Region Inference](https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference.html)。

### 1.2 配额类型

| 配额 | 可调 | 说明 |
|------|------|------|
| Cross-region TPM / RPM | ✅ | `us.*` 前缀，通过 Service Quotas 申请 |
| Global cross-region TPM / RPM | ✅ | `global.*` 前缀，通过 Service Quotas 申请 |
| Model invocation max TPD | ❌ | 注明 "doubled for cross-region calls"，需联系 AWS Support |

配额在同一 inference profile 的所有区域间**共享**。每个账户配额不同，通过以下方式查询：
- **控制台**：Service Quotas → Amazon Bedrock → 搜 "Claude"
- **CLI**：
  ```bash
  # 查所有 Claude 相关配额（TPM/RPM/TPD）
  aws service-quotas list-service-quotas --service-code bedrock \
    --query 'Quotas[?contains(QuotaName, `Claude`)].[QuotaName,Value]' --output table
  ```

> 配额增加流程见 [Requesting a quota increase](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas-increase.html)。

### 1.3 Token Burndown Rate

Claude 3.7 及以后版本 output tokens 按 **5 倍**扣减 TPM/TPD 配额：

```
预扣 = InputTokens + max_tokens
实际 = InputTokens + CacheWriteInputTokens + (OutputTokens × 5)
CacheReadInputTokens 不计入
```

**建议**：`max_tokens` 设为接近实际需求值，避免预扣过大。

> 详见 [Token Burndown Rate](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas-token-burndown.html)。

---

## 二、限流预防

### 2.1 告警策略

| 级别 | 条件 | 响应 |
|------|------|------|
| 🔴 P0 | `InvocationThrottles ≥ 1` | 立即通知 |
| 🟡 P1 | TPM > 70%（持续 3 min）或 p99 > 30s | 5 分钟通知 |
| 🟢 P2 | 日 Token > 50% TPD 或费用 > 预算 80% | 每日通知 |

### 2.2 TPM/RPM 使用率

三种方式监控：

1. **`EstimatedTPMQuotaUsage`**（推荐）：CloudWatch 原生指标，直接对比配额值设告警
2. **Metric Math**：`(InputTokenCount + OutputTokenCount × 5) / TPM_QUOTA × 100`
3. **Service Quotas 告警**：控制台原生支持百分比告警，推荐 70% + 90% 两级

---

## 三、成本维度

如果还需要从成本角度监控，Cost Explorer 可以按 model 和 operation 拆分 Bedrock 的费用。

```bash
# 查看最近 7 天按模型的 Bedrock 费用
aws ce get-cost-and-usage \
  --time-period Start=$(date -v-7d +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity DAILY \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Bedrock"]}}' \
  --group-by Type=DIMENSION,Key=USAGE_TYPE \
  --metrics UnblendedCost
```

> 数据延迟 ~24h。建议配合 Cost Anomaly Detection（Service = Bedrock + SNS 通知）自动检测费用突增。

---

## 四、Cross-Region 注意事项

| 要点 | 说明 |
|------|------|
| ModelId 映射 | `global.*` 在 CloudWatch 显示为 `eu.*`/`us.*`，Dashboard 需覆盖所有 prefix |
| 配额共享 | Cross-Region 全局共享，一处耗尽 = 所有区域 429 |
| 告警 Region | 限流指标（Throttles）在发起调用的 Region；延迟/Token 指标在路由到的 Region |

> 路由机制详见 [Cross-Region Inference](https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference.html)。

---

## 五、Gotchas（实测验证）

| # | 问题 | 处理 |
|---|------|------|
| 1 | `TimeToFirstToken` / `EstimatedTPMQuotaUsage` 需有调用数据后才出现 | 新账户初期用 Metric Math 替代 |
| 2 | `global.*` ModelId 在 CloudWatch 显示为 `eu.*`/`us.*` | Dashboard 需覆盖所有 prefix |
| 3 | `InvocationClientErrors` 含所有 4xx | 优先用 `InvocationThrottles` 判断限流 |
| 4 | Service Quotas 1000+ 条目 | CLI 查询用 `--query` 过滤 |
| 5 | Claude 4.x 无 Regional On-Demand 配额 | 必须用 Cross-Region 或 Global Cross-Region Inference |
| 6 | Claude 3.7+ output burndown rate = 5x | `max_tokens` 设为实际需求值 |

---

## 六、实施优先级

**P0**：`InvocationThrottles ≥ 1` 告警 + Cost Anomaly Detection
**P1**：TPM/RPM 使用率告警（70%+90%）+ Model Invocation Logging + Dashboard
**P2**：`max_tokens` 优化 + Prompt Cache 优化

