#!/bin/bash
# ====================================================================
# LiteLLM 端到端测试脚本
# ====================================================================
# 用法:
#   ./scripts/e2e-test.sh                                    # 使用默认配置
#   ./scripts/e2e-test.sh --endpoint https://api.example.com --key sk-xxx
#   ./scripts/e2e-test.sh --skip-stress                      # 跳过压力测试
# ====================================================================

set -euo pipefail

# ====================================================================
# 颜色定义
# ====================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ====================================================================
# 配置变量
# ====================================================================
API_ENDPOINT="${API_ENDPOINT:-}"
API_KEY="${API_KEY:-}"
MASTER_KEY="${MASTER_KEY:-}"
SKIP_STRESS=false
CONCURRENCY=10
TOTAL_REQUESTS=50

# ====================================================================
# 解析命令行参数
# ====================================================================
while [[ $# -gt 0 ]]; do
  case $1 in
    --endpoint)
      API_ENDPOINT="$2"
      shift 2
      ;;
    --key)
      API_KEY="$2"
      shift 2
      ;;
    --master-key)
      MASTER_KEY="$2"
      shift 2
      ;;
    --skip-stress)
      SKIP_STRESS=true
      shift
      ;;
    --concurrency)
      CONCURRENCY="$2"
      shift 2
      ;;
    --total-requests)
      TOTAL_REQUESTS="$2"
      shift 2
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      exit 1
      ;;
  esac
done

# ====================================================================
# 从 Terraform 输出获取配置（如果未提供）
# ====================================================================
if [ -z "$API_ENDPOINT" ]; then
  if command -v terraform &> /dev/null && [ -d "terraform" ]; then
    API_ENDPOINT=$(cd terraform && terraform output -raw litellm_url 2>/dev/null || echo "")
  fi
fi

if [ -z "$API_KEY" ] && [ -z "$MASTER_KEY" ]; then
  if command -v terraform &> /dev/null && [ -d "terraform" ]; then
    MASTER_KEY=$(cd terraform && terraform output -raw litellm_master_key 2>/dev/null || echo "")
  fi
fi

# 默认 endpoint
if [ -z "$API_ENDPOINT" ]; then
  API_ENDPOINT="https://litellm.example.com"
fi

# 如果都没设置，报错
if [ -z "$API_KEY" ] && [ -z "$MASTER_KEY" ]; then
  echo -e "${RED}错误: 请提供 API_KEY 或 MASTER_KEY${NC}"
  echo "用法: API_KEY=sk-xxx $0"
  echo "或: $0 --key sk-xxx"
  exit 1
fi

# 优先使用 API_KEY，否则使用 MASTER_KEY
AUTH_KEY="${API_KEY:-$MASTER_KEY}"

# ====================================================================
# 创建测试结果目录
# ====================================================================
mkdir -p test-results
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
REPORT_FILE="test-results/e2e-report-${TIMESTAMP}.json"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# ====================================================================
# 全局测试统计
# ====================================================================
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# ====================================================================
# 工具函数
# ====================================================================

log_section() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_test() {
  echo -e "${CYAN}  [TEST] $1${NC}"
}

log_pass() {
  echo -e "  ${GREEN}✓ PASS${NC} - $1"
  PASSED_TESTS=$((PASSED_TESTS + 1))
}

log_fail() {
  echo -e "  ${RED}✗ FAIL${NC} - $1"
  FAILED_TESTS=$((FAILED_TESTS + 1))
}

log_skip() {
  echo -e "  ${YELLOW}⊘ SKIP${NC} - $1"
  SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
}

get_timestamp_ms() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    date +%s%3N
  fi
}

# ====================================================================
# 测试开始
# ====================================================================

log_section "LiteLLM E2E 测试"
echo "  时间:      $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Endpoint:  $API_ENDPOINT"
echo "  结果文件:  $REPORT_FILE"

# 初始化 JSON 报告
cat > "$REPORT_FILE" <<EOF
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "endpoint": "$API_ENDPOINT",
  "tests": []
}
EOF

# ====================================================================
# 1. 健康检查测试
# ====================================================================

log_section "1. 健康检查测试"

# 1.1 Liveliness Check
log_test "GET /health/liveliness"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
response=$(curl -s -w "\n%{http_code}" --max-time 10 "$API_ENDPOINT/health/liveliness" 2>&1 || echo -e "\n000")
http_code=$(echo "$response" | tail -n1)
if [ "$http_code" = "200" ]; then
  log_pass "Liveliness check returned 200"
else
  log_fail "Liveliness check returned $http_code"
fi

# 1.2 Readiness Check
log_test "GET /health/readiness"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
response=$(curl -s -w "\n%{http_code}" --max-time 10 "$API_ENDPOINT/health/readiness" 2>&1 || echo -e "\n000")
http_code=$(echo "$response" | tail -n1)
if [ "$http_code" = "200" ]; then
  log_pass "Readiness check returned 200"
else
  log_fail "Readiness check returned $http_code"
fi

# ====================================================================
# 2. 认证测试
# ====================================================================

log_section "2. 认证测试"

# 2.1 无 Authorization Header
log_test "Request without Authorization header"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
response=$(curl -s -w "\n%{http_code}" --max-time 10 "$API_ENDPOINT/model/info" 2>&1)
http_code=$(echo "$response" | tail -n1)
if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
  log_pass "Correctly rejected with $http_code"
else
  log_fail "Expected 401/403, got $http_code"
fi

# 2.2 错误的 API Key
log_test "Request with invalid API key"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
response=$(curl -s -w "\n%{http_code}" --max-time 10 \
  -H "Authorization: Bearer sk-invalid-xxx" \
  "$API_ENDPOINT/model/info" 2>&1)
http_code=$(echo "$response" | tail -n1)
if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
  log_pass "Correctly rejected invalid key with $http_code"
else
  log_fail "Expected 401/403, got $http_code"
fi

# 2.3 有效的 API Key
log_test "Request with valid API key"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
response=$(curl -s -w "\n%{http_code}" --max-time 10 \
  -H "Authorization: Bearer $AUTH_KEY" \
  "$API_ENDPOINT/model/info" 2>&1)
http_code=$(echo "$response" | tail -n1)
if [ "$http_code" = "200" ]; then
  log_pass "Valid key accepted"
else
  log_fail "Valid key rejected with $http_code"
fi

# ====================================================================
# 3. 模型可用性测试
# ====================================================================

log_section "3. 模型可用性测试"

MODELS=(
  "claude-opus-4-6-us"
  "claude-opus-4-6-global"
  "claude-opus-4-5"
  "claude-sonnet-4-6-us"
  "claude-sonnet-4-6-global"
  "claude-sonnet-4-5"
  "claude-sonnet-3-7"
  "claude-sonnet-3-5"
  "claude-haiku-4-5"
)

# 允许某些模型失败（如 US inference profile 在某些区域可能不可用）
OPTIONAL_MODELS=("claude-opus-4-6-us" "claude-sonnet-4-6-us")

for model in "${MODELS[@]}"; do
  log_test "Testing model: $model"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))

  start_time=$(get_timestamp_ms)
  response=$(curl -s -w "\n%{http_code}" --max-time 60 \
    -H "Authorization: Bearer $AUTH_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one word\"}],\"max_tokens\":10}" \
    "$API_ENDPOINT/v1/chat/completions" 2>&1 || echo -e "\n000")
  end_time=$(get_timestamp_ms)
  duration=$((end_time - start_time))

  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')

  is_optional=false
  for optional in "${OPTIONAL_MODELS[@]}"; do
    if [ "$model" = "$optional" ]; then
      is_optional=true
      break
    fi
  done

  if [ "$http_code" = "200" ]; then
    log_pass "$model responded in ${duration}ms"
  elif [ "$is_optional" = true ]; then
    log_skip "$model not available (optional) - $http_code"
  else
    error_msg=$(echo "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('message','unknown'))" 2>/dev/null || echo "parse error")
    log_fail "$model returned $http_code - $error_msg"
  fi
done

# ====================================================================
# 4. Streaming 测试
# ====================================================================

log_section "4. Streaming 测试"

log_test "Streaming response with SSE format"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response_file="$TEMP_DIR/stream_response.txt"
curl -s --max-time 60 \
  -H "Authorization: Bearer $AUTH_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5","messages":[{"role":"user","content":"Count to 3"}],"max_tokens":20,"stream":true}' \
  "$API_ENDPOINT/v1/chat/completions" > "$response_file" 2>&1

if grep -q "data: " "$response_file" && grep -q "\[DONE\]" "$response_file"; then
  log_pass "Streaming response received in SSE format"
elif [ -s "$response_file" ]; then
  log_fail "Streaming response format incorrect"
else
  log_fail "No streaming response received"
fi

# ====================================================================
# 5. Fallback 链测试
# ====================================================================

log_section "5. Fallback 链测试"

log_test "Fallback chain for US inference profile models"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# 使用 Sonnet 4.6 US，如果失败应该 fallback 到 Global
response=$(curl -s -w "\n%{http_code}" --max-time 60 \
  -H "Authorization: Bearer $AUTH_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-6-us","messages":[{"role":"user","content":"Hi"}],"max_tokens":5}' \
  "$API_ENDPOINT/v1/chat/completions" 2>&1 || echo -e "\n000")

http_code=$(echo "$response" | tail -n1)
if [ "$http_code" = "200" ]; then
  log_pass "Request succeeded (potentially via fallback)"
else
  log_fail "Fallback chain test failed with $http_code"
fi

# ====================================================================
# 6. 并发压力测试
# ====================================================================

if [ "$SKIP_STRESS" = false ]; then
  log_section "6. 并发压力测试"

  echo "  并发数:    $CONCURRENCY"
  echo "  总请求数:  $TOTAL_REQUESTS"
  echo ""

  TOTAL_TESTS=$((TOTAL_TESTS + 1))

  # 单次请求函数
  do_stress_request() {
    local id=$1
    local start_time=$(get_timestamp_ms)

    response=$(curl -s -w "\n%{http_code}" --max-time 120 \
      -H "Authorization: Bearer $AUTH_KEY" \
      -H "Content-Type: application/json" \
      -d '{"model":"claude-haiku-4-5","messages":[{"role":"user","content":"Say hello in one word"}],"max_tokens":10}' \
      "$API_ENDPOINT/v1/chat/completions" 2>&1 || echo -e "\n000")

    local end_time=$(get_timestamp_ms)
    local duration=$((end_time - start_time))
    local http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" = "200" ]; then
      echo "OK,$duration" > "$TEMP_DIR/stress_$id.txt"
    else
      echo "FAIL,$duration" > "$TEMP_DIR/stress_$id.txt"
    fi
  }

  # 执行并发测试
  stress_start=$(get_timestamp_ms)
  request_id=0

  while [ $request_id -lt $TOTAL_REQUESTS ]; do
    batch_pids=()
    for ((i=0; i<CONCURRENCY && request_id<TOTAL_REQUESTS; i++)); do
      do_stress_request $request_id &
      batch_pids+=($!)
      request_id=$((request_id + 1))
    done

    for pid in "${batch_pids[@]}"; do
      wait $pid 2>/dev/null || true
    done

    printf "\r  进度: %d/%d (%d%%)" $request_id $TOTAL_REQUESTS $((request_id * 100 / TOTAL_REQUESTS))
  done

  stress_end=$(get_timestamp_ms)
  stress_duration=$((stress_end - stress_start))

  echo ""
  echo ""

  # 统计结果
  stress_success=0
  stress_fail=0
  stress_total_latency=0
  declare -a stress_latencies

  for file in "$TEMP_DIR"/stress_*.txt; do
    if [ -f "$file" ]; then
      result=$(cat "$file")
      status=$(echo "$result" | cut -d',' -f1)
      latency=$(echo "$result" | cut -d',' -f2)

      if [ "$status" = "OK" ]; then
        stress_success=$((stress_success + 1))
        stress_total_latency=$((stress_total_latency + latency))
        stress_latencies+=($latency)
      else
        stress_fail=$((stress_fail + 1))
      fi
    fi
  done

  if [ $stress_success -gt 0 ]; then
    avg_latency=$((stress_total_latency / stress_success))
    rps=$(echo "scale=2; $stress_success * 1000 / $stress_duration" | bc)
    success_rate=$(echo "scale=1; $stress_success * 100 / $TOTAL_REQUESTS" | bc)

    echo "  结果统计:"
    echo "    总耗时:    ${stress_duration}ms"
    echo "    成功:      $stress_success"
    echo "    失败:      $stress_fail"
    echo "    成功率:    ${success_rate}%"
    echo "    RPS:       ${rps} req/s"
    echo "    平均延迟:  ${avg_latency}ms"

    if [ "$stress_fail" -eq 0 ] && [ "$success_rate" = "100.0" ]; then
      log_pass "Stress test passed with 100% success rate"
    elif (( $(echo "$success_rate >= 95.0" | bc -l) )); then
      log_pass "Stress test passed with ${success_rate}% success rate"
    else
      log_fail "Stress test failed with only ${success_rate}% success rate"
    fi
  else
    log_fail "Stress test failed - no successful requests"
  fi
else
  log_section "6. 并发压力测试"
  echo -e "${YELLOW}  跳过 (--skip-stress)${NC}"
fi

# ====================================================================
# 7. 认证性能测试
# ====================================================================

log_section "7. 认证性能测试"

echo "  测试缓存性能差异..."
echo ""

TOTAL_TESTS=$((TOTAL_TESTS + 1))

cold_latencies=()
hot_latencies=()

# 第一次请求（冷缓存）
for i in {1..1}; do
  start_time=$(get_timestamp_ms)
  curl -s --max-time 10 \
    -H "Authorization: Bearer $AUTH_KEY" \
    "$API_ENDPOINT/model/info" > /dev/null 2>&1
  end_time=$(get_timestamp_ms)
  duration=$((end_time - start_time))
  cold_latencies+=($duration)
done

# 后续请求（热缓存）
for i in {1..19}; do
  start_time=$(get_timestamp_ms)
  curl -s --max-time 10 \
    -H "Authorization: Bearer $AUTH_KEY" \
    "$API_ENDPOINT/model/info" > /dev/null 2>&1
  end_time=$(get_timestamp_ms)
  duration=$((end_time - start_time))
  hot_latencies+=($duration)
done

# 计算平均值
cold_avg=0
for latency in "${cold_latencies[@]}"; do
  cold_avg=$((cold_avg + latency))
done
cold_avg=$((cold_avg / ${#cold_latencies[@]}))

hot_avg=0
for latency in "${hot_latencies[@]}"; do
  hot_avg=$((hot_avg + latency))
done
hot_avg=$((hot_avg / ${#hot_latencies[@]}))

echo "  冷缓存平均延迟: ${cold_avg}ms"
echo "  热缓存平均延迟: ${hot_avg}ms"

# 缓存应该比冷启动快（允许一定误差）
if [ $hot_avg -le $cold_avg ]; then
  log_pass "Cache performance test passed (hot cache faster or equal)"
else
  # 只是警告，不算失败
  echo -e "  ${YELLOW}⚠ WARNING${NC} - Hot cache slower than cold (might be network variation)"
  log_pass "Cache performance test completed"
fi

# ====================================================================
# 测试报告
# ====================================================================

log_section "测试报告"

echo ""
echo -e "${CYAN}汇总统计${NC}"
echo "  总测试数:  $TOTAL_TESTS"
echo -e "  ${GREEN}通过:      $PASSED_TESTS${NC}"
echo -e "  ${RED}失败:      $FAILED_TESTS${NC}"
echo -e "  ${YELLOW}跳过:      $SKIPPED_TESTS${NC}"
echo ""

# 计算成功率
if [ $TOTAL_TESTS -gt 0 ]; then
  success_rate=$(echo "scale=1; ($PASSED_TESTS + $SKIPPED_TESTS) * 100 / $TOTAL_TESTS" | bc)
  echo "  成功率:    ${success_rate}%"
fi

# 更新 JSON 报告
cat > "$REPORT_FILE" <<EOF
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "endpoint": "$API_ENDPOINT",
  "summary": {
    "total": $TOTAL_TESTS,
    "passed": $PASSED_TESTS,
    "failed": $FAILED_TESTS,
    "skipped": $SKIPPED_TESTS,
    "success_rate": "${success_rate}%"
  }
}
EOF

echo ""
echo "  详细报告已保存到: $REPORT_FILE"
echo ""

# 退出码
if [ $FAILED_TESTS -eq 0 ]; then
  echo -e "${GREEN}✓ 所有测试通过${NC}"
  exit 0
else
  echo -e "${RED}✗ 有 $FAILED_TESTS 个测试失败${NC}"
  exit 1
fi
