#!/bin/bash
# LiteLLM 压测脚本
# 用法: ./scripts/benchmark.sh [并发数] [总请求数] [模型名称]
# 示例: ./scripts/benchmark.sh 10 100 claude-sonnet-3-5

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置
LITELLM_URL="${LITELLM_URL:-https://litellm.example.com}"
API_KEY="${API_KEY:-${LITELLM_MASTER_KEY:-}}"
CONCURRENCY="${1:-5}"
TOTAL_REQUESTS="${2:-20}"
MODEL="${3:-claude-sonnet-3-5}"

# 如果没有设置 API_KEY，尝试从 kubernetes secret 获取
if [ -z "$API_KEY" ]; then
    echo -e "${YELLOW}从 Kubernetes secret 获取 MASTER_KEY...${NC}"
    API_KEY=$(kubectl get secret litellm-secrets -n litellm -o jsonpath='{.data.LITELLM_MASTER_KEY}' 2>/dev/null | base64 -d) || true
fi

if [ -z "$API_KEY" ]; then
    echo -e "${RED}错误: 请设置 API_KEY 或 LITELLM_MASTER_KEY 环境变量${NC}"
    echo "用法: API_KEY=sk-xxx $0 [并发数] [总请求数] [模型名称]"
    exit 1
fi

# 创建临时目录
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# 获取毫秒时间戳
get_timestamp_ms() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        python3 -c 'import time; print(int(time.time() * 1000))'
    else
        date +%s%3N
    fi
}

# 单次请求函数
do_request() {
    local id=$1
    local start_time=$(get_timestamp_ms)

    response=$(curl -s -w "\n%{http_code}" --max-time 120 \
        "${LITELLM_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${API_KEY}" \
        -d "{
            \"model\": \"${MODEL}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one word\"}],
            \"max_tokens\": 10
        }" 2>&1)

    local end_time=$(get_timestamp_ms)
    local duration=$((end_time - start_time))

    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ]; then
        local tokens=$(echo "$body" | jq -r '.usage.total_tokens // 0')
        echo "OK,$duration,$tokens" > "$TMPDIR/result_$id.txt"
    else
        echo "FAIL,$duration,0" > "$TMPDIR/result_$id.txt"
    fi
}

echo ""
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}   LiteLLM 压力测试${NC}"
echo -e "${BLUE}================================================${NC}"
echo -e "URL:       ${LITELLM_URL}"
echo -e "模型:      ${MODEL}"
echo -e "并发数:    ${CONCURRENCY}"
echo -e "总请求数:  ${TOTAL_REQUESTS}"
echo -e "时间:      $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 验证模型是否存在
echo -e "${YELLOW}验证模型可用性...${NC}"
check_response=$(curl -s --max-time 30 \
    "${LITELLM_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "{
        \"model\": \"${MODEL}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Hi\"}],
        \"max_tokens\": 5
    }" 2>&1)

if echo "$check_response" | jq -e '.error' > /dev/null 2>&1; then
    echo -e "${RED}模型验证失败: $(echo "$check_response" | jq -r '.error.message // .detail // "unknown"')${NC}"
    exit 1
fi
echo -e "${GREEN}模型验证通过${NC}"
echo ""

# 执行压测
echo -e "${YELLOW}开始压测...${NC}"
echo ""

BENCHMARK_START=$(get_timestamp_ms)

# 并发执行请求
request_id=0
while [ $request_id -lt $TOTAL_REQUESTS ]; do
    # 启动一批并发请求
    batch_pids=()
    for ((i=0; i<CONCURRENCY && request_id<TOTAL_REQUESTS; i++)); do
        do_request $request_id &
        batch_pids+=($!)
        request_id=$((request_id + 1))
    done

    # 等待这批请求完成
    for pid in "${batch_pids[@]}"; do
        wait $pid 2>/dev/null || true
    done

    # 显示进度
    printf "\r  进度: %d/%d (%d%%)" $request_id $TOTAL_REQUESTS $((request_id * 100 / TOTAL_REQUESTS))
done

BENCHMARK_END=$(get_timestamp_ms)
TOTAL_DURATION=$((BENCHMARK_END - BENCHMARK_START))

echo ""
echo ""

# 统计结果
SUCCESS=0
FAIL=0
TOTAL_LATENCY=0
MIN_LATENCY=999999
MAX_LATENCY=0
TOTAL_TOKENS=0
declare -a LATENCIES

for file in "$TMPDIR"/result_*.txt; do
    if [ -f "$file" ]; then
        result=$(cat "$file")
        status=$(echo "$result" | cut -d',' -f1)
        latency=$(echo "$result" | cut -d',' -f2)
        tokens=$(echo "$result" | cut -d',' -f3)

        if [ "$status" = "OK" ]; then
            SUCCESS=$((SUCCESS + 1))
            TOTAL_LATENCY=$((TOTAL_LATENCY + latency))
            TOTAL_TOKENS=$((TOTAL_TOKENS + tokens))
            LATENCIES+=($latency)

            if [ $latency -lt $MIN_LATENCY ]; then
                MIN_LATENCY=$latency
            fi
            if [ $latency -gt $MAX_LATENCY ]; then
                MAX_LATENCY=$latency
            fi
        else
            FAIL=$((FAIL + 1))
        fi
    fi
done

# 计算统计值
if [ $SUCCESS -gt 0 ]; then
    AVG_LATENCY=$((TOTAL_LATENCY / SUCCESS))

    # 计算 P50, P90, P99
    IFS=$'\n' SORTED_LATENCIES=($(sort -n <<<"${LATENCIES[*]}")); unset IFS
    P50_INDEX=$((SUCCESS * 50 / 100))
    P90_INDEX=$((SUCCESS * 90 / 100))
    P99_INDEX=$((SUCCESS * 99 / 100))
    if [ $P50_INDEX -ge $SUCCESS ]; then P50_INDEX=$((SUCCESS - 1)); fi
    if [ $P90_INDEX -ge $SUCCESS ]; then P90_INDEX=$((SUCCESS - 1)); fi
    if [ $P99_INDEX -ge $SUCCESS ]; then P99_INDEX=$((SUCCESS - 1)); fi
    P50_LATENCY=${SORTED_LATENCIES[$P50_INDEX]}
    P90_LATENCY=${SORTED_LATENCIES[$P90_INDEX]}
    P99_LATENCY=${SORTED_LATENCIES[$P99_INDEX]}

    # 计算 RPS
    RPS=$(echo "scale=2; $SUCCESS * 1000 / $TOTAL_DURATION" | bc)
else
    AVG_LATENCY=0
    P50_LATENCY=0
    P90_LATENCY=0
    P99_LATENCY=0
    RPS=0
fi

SUCCESS_RATE=$(echo "scale=1; $SUCCESS * 100 / $TOTAL_REQUESTS" | bc)

# 输出结果
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}   压测结果${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo -e "${CYAN}请求统计${NC}"
echo -e "  总请求数:     ${TOTAL_REQUESTS}"
echo -e "  ${GREEN}成功:         ${SUCCESS}${NC}"
echo -e "  ${RED}失败:         ${FAIL}${NC}"
echo -e "  成功率:       ${SUCCESS_RATE}%"
echo ""
echo -e "${CYAN}性能指标${NC}"
echo -e "  总耗时:       ${TOTAL_DURATION}ms"
echo -e "  RPS:          ${RPS} req/s"
echo -e "  平均延迟:     ${AVG_LATENCY}ms"
echo -e "  最小延迟:     ${MIN_LATENCY}ms"
echo -e "  最大延迟:     ${MAX_LATENCY}ms"
echo -e "  P50 延迟:     ${P50_LATENCY}ms"
echo -e "  P90 延迟:     ${P90_LATENCY}ms"
echo -e "  P99 延迟:     ${P99_LATENCY}ms"
echo ""
echo -e "${CYAN}Token 使用${NC}"
echo -e "  总 Tokens:    ${TOTAL_TOKENS}"
echo ""

# 退出码
if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}压测完成，无失败请求${NC}"
    exit 0
else
    echo -e "${YELLOW}压测完成，有 ${FAIL} 个失败请求${NC}"
    exit 1
fi
