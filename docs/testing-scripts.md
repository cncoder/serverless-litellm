# 测试脚本使用指南

本目录包含三个测试脚本，用于验证 LiteLLM 部署的功能和性能。

## 脚本概览

| 脚本 | 用途 | 执行时间 |
|------|------|----------|
| `e2e-test.sh` | 完整的端到端测试套件 | ~2-5 分钟 |
| `test-models.sh` | 测试所有模型的可用性 | ~1-2 分钟 |
| `benchmark.sh` | 并发压力测试 | ~30-60 秒 |

## 1. E2E 测试 (推荐)

完整的端到端测试套件，包含健康检查、认证、模型可用性、流式输出、fallback 链、并发压力、缓存性能等测试。

### 基本用法

```bash
# 使用环境变量
export API_KEY="sk-xxx"
./scripts/e2e-test.sh

# 或使用命令行参数
./scripts/e2e-test.sh --endpoint https://litellm.example.com --key sk-xxx

# 跳过压力测试（快速验证）
./scripts/e2e-test.sh --skip-stress

# 自定义压力测试参数
./scripts/e2e-test.sh --concurrency 20 --total-requests 100
```

### 输出示例

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. 健康检查测试
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [TEST] GET /health/liveliness
  ✓ PASS - Liveliness check returned 200
  [TEST] GET /health/readiness
  ✓ PASS - Readiness check returned 200
```

### 测试报告

测试完成后会生成 JSON 格式的详细报告：

```bash
test-results/e2e-report-20260226_235900.json
```

## 2. 模型测试

测试所有配置的模型，使用英文和中文 prompt 各测试一次。

### 基本用法

```bash
# 使用环境变量
export API_KEY="sk-xxx"
./scripts/test-models.sh

# 或使用命令行参数
./scripts/test-models.sh https://litellm.example.com sk-xxx
```

### 输出示例

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  LiteLLM 模型测试
  时间: 2026-02-26 23:59:00    URL: https://litellm.example.com
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [1/9] claude-opus-4-6-us
    EN  [OK]   1.23s  I am Claude Opus 4.6
    ZH  [OK]   1.45s  我是 Claude Opus 4.6 模型
```

## 3. 压力测试

并发测试单个模型的性能。

### 基本用法

```bash
# 使用环境变量
export API_KEY="sk-xxx"
./scripts/benchmark.sh

# 自定义参数：并发数 总请求数 模型名称
./scripts/benchmark.sh 10 100 claude-haiku-4-5

# 使用环境变量指定 URL
export LITELLM_URL="https://litellm.example.com"
./scripts/benchmark.sh 20 200 claude-sonnet-4-5
```

### 输出示例

```
================================================
   压测结果
================================================

请求统计
  总请求数:     100
  成功:         100
  失败:         0
  成功率:       100.0%

性能指标
  总耗时:       12345ms
  RPS:          8.10 req/s
  平均延迟:     1234ms
  最小延迟:     890ms
  最大延迟:     2100ms
  P50 延迟:     1200ms
  P90 延迟:     1800ms
  P99 延迟:     2000ms
```

## 环境变量

所有脚本支持以下环境变量：

| 变量 | 说明 | 示例 |
|------|------|------|
| `API_KEY` | LiteLLM API Key | `sk-xxx` |
| `LITELLM_MASTER_KEY` | LiteLLM Master Key (备选) | `sk-xxx` |
| `LITELLM_URL` | LiteLLM API Endpoint | `https://litellm.example.com` |
| `API_ENDPOINT` | 同 LITELLM_URL (e2e-test.sh) | `https://api.example.com` |

## CI/CD 集成

### GitHub Actions 示例

```yaml
- name: Run E2E Tests
  env:
    API_KEY: ${{ secrets.LITELLM_API_KEY }}
    API_ENDPOINT: https://litellm.example.com
  run: |
    ./scripts/e2e-test.sh --skip-stress
```

### 测试失败时退出码

- E2E 测试: 任何测试失败 → exit 1
- 模型测试: 任何模型失败 → exit 非零
- 压力测试: 有失败请求 → exit 1

## 故障排查

### 认证失败

```
错误: 请提供 API_KEY
```

**解决方案**: 设置 `API_KEY` 环境变量或使用 `--key` 参数

### 连接超时

```
FAIL - HTTP 000
```

**解决方案**: 检查网络连接和 endpoint 地址是否正确

### 模型不可用

```
SKIP - claude-opus-4-6-us not available (optional) - 400
```

**说明**: US inference profile 模型在某些区域可能不可用，这是正常的。E2E 测试会自动跳过这些可选模型。

## 最佳实践

1. **部署后验证**: 每次部署后运行 `e2e-test.sh` 确保一切正常
2. **定期压测**: 使用 `benchmark.sh` 监控性能变化
3. **模型验证**: 添加新模型后用 `test-models.sh` 验证
4. **CI 集成**: 在 CI pipeline 中运行 e2e-test（跳过压力测试以节省时间）
5. **保存报告**: E2E 测试报告保存在 `test-results/` 目录，建议定期归档

## 相关文件

- 模型配置: `kubernetes/configmap.yaml`
- 部署脚本: `scripts/setup.sh`
- Key 管理: `scripts/manage-keys.sh`
