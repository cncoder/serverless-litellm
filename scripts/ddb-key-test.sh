#!/bin/bash
# ====================================================================
# DynamoDB Key 批量创建 + 随机抽样全模型验证
# ====================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

TABLE_NAME="${DYNAMODB_TABLE:-litellm-prod-api-keys}"
REGION="${AWS_REGION:-ap-northeast-1}"
ENDPOINT="${API_ENDPOINT:-https://litellm.example.com}"
TOTAL_KEYS=100
SAMPLE_SIZE=10

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

log_section() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ====================================================================
# Step 1: 批量写入 100 个 key
# ====================================================================
log_section "Step 1: 批量写入 ${TOTAL_KEYS} 个 key 到 DynamoDB"

KEYS=()
BATCH_SIZE=25  # DynamoDB batch write 单次最多 25 条
TIMESTAMP=$(date +%s)

echo "  正在生成并写入..."

for batch_start in $(seq 0 $BATCH_SIZE $((TOTAL_KEYS - 1))); do
  batch_end=$((batch_start + BATCH_SIZE - 1))
  if [ $batch_end -ge $TOTAL_KEYS ]; then
    batch_end=$((TOTAL_KEYS - 1))
  fi

  # 构建 batch write JSON
  items_json=""
  for i in $(seq $batch_start $batch_end); do
    key="sk-test-$(printf '%04d' $i)-${TIMESTAMP}"
    KEYS+=("$key")

    # 随机分配预算 ($1-$100) 和用户
    budget=$(( (RANDOM % 100) + 1 ))
    user_id="user-$(printf '%03d' $((i % 20 + 1)))"

    if [ -n "$items_json" ]; then
      items_json="${items_json},"
    fi
    items_json="${items_json}{
      \"PutRequest\": {
        \"Item\": {
          \"api_key\": {\"S\": \"${key}\"},
          \"user_id\": {\"S\": \"${user_id}\"},
          \"enabled\": {\"BOOL\": true},
          \"max_budget\": {\"N\": \"${budget}\"},
          \"created_at\": {\"S\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},
          \"description\": {\"S\": \"batch-test-key-${i}\"}
        }
      }
    }"
  done

  # 执行 batch write
  aws dynamodb batch-write-item \
    --region "$REGION" \
    --request-items "{\"${TABLE_NAME}\": [${items_json}]}" \
    --output json > /dev/null

  printf "\r  进度: %d/%d" "$((batch_end + 1))" "$TOTAL_KEYS"
done

echo ""
echo -e "  ${GREEN}✓ 已写入 ${TOTAL_KEYS} 个 key${NC}"

# 将 keys 存到临时文件
KEYS_FILE=$(mktemp)
printf '%s\n' "${KEYS[@]}" > "$KEYS_FILE"

# ====================================================================
# Step 2: 验证写入 - 扫描计数
# ====================================================================
log_section "Step 2: 验证写入"

TOTAL_IN_DB=$(aws dynamodb scan \
  --table-name "$TABLE_NAME" \
  --region "$REGION" \
  --select COUNT \
  --query 'Count' \
  --output text)

echo "  DynamoDB 表中共有 ${TOTAL_IN_DB} 条记录"

# ====================================================================
# Step 3: 随机抽取 10 个 key
# ====================================================================
log_section "Step 3: 随机抽取 ${SAMPLE_SIZE} 个 key"

# 从刚写入的 keys 中随机抽 10 个（兼容 macOS，无 shuf）
SAMPLED_KEYS=()
while IFS= read -r key; do
  SAMPLED_KEYS+=("$key")
done < <(python3 -c "
import random, sys
keys = open('$KEYS_FILE').read().splitlines()
print('\n'.join(random.sample(keys, $SAMPLE_SIZE)))
")
rm "$KEYS_FILE"

echo "  抽取到的 key："
for i in "${!SAMPLED_KEYS[@]}"; do
  echo "    $((i+1)). ${SAMPLED_KEYS[$i]}"
done

# ====================================================================
# Step 4: 全模型验证
# ====================================================================
log_section "Step 4: 全模型验证（${SAMPLE_SIZE} keys × ${#MODELS[@]} models）"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

get_ts_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

for key_idx in "${!SAMPLED_KEYS[@]}"; do
  KEY="${SAMPLED_KEYS[$key_idx]}"
  KEY_SHORT="${KEY:0:20}..."
  echo ""
  echo -e "  ${CYAN}[Key $((key_idx+1))/${SAMPLE_SIZE}] ${KEY_SHORT}${NC}"

  for model in "${MODELS[@]}"; do
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    t0=$(get_ts_ms)
    response=$(curl -s -w "\n%{http_code}" --max-time 30 \
      -H "Authorization: Bearer $KEY" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one word: OK\"}],\"max_tokens\":5}" \
      "$ENDPOINT/v1/chat/completions" 2>/dev/null || echo -e "\n000")
    t1=$(get_ts_ms)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    duration=$((t1 - t0))

    if [ "$http_code" = "200" ]; then
      reply=$(echo "$body" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d['choices'][0]['message']['content'].strip()[:20])
except:
    print('?')
" 2>/dev/null)
      printf "    ${GREEN}✓${NC} %-30s %4dms  %s\n" "$model" "$duration" "$reply"
      PASSED_TESTS=$((PASSED_TESTS + 1))
    else
      err=$(echo "$body" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('error',{}).get('message','unknown')[:50])
except:
    print('parse error')
" 2>/dev/null)
      printf "    ${RED}✗${NC} %-30s %4dms  HTTP $http_code - $err\n" "$model" "$duration"
      FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
  done
done

# ====================================================================
# Step 5: 清理 - 删除所有测试 key
# ====================================================================
log_section "Step 5: 清理测试 key"

echo "  正在删除 ${TOTAL_KEYS} 个测试 key..."

# 扫描并删除所有 sk-test- 前缀的 key
DELETE_COUNT=0
while IFS= read -r key; do
  aws dynamodb delete-item \
    --table-name "$TABLE_NAME" \
    --region "$REGION" \
    --key "{\"api_key\": {\"S\": \"$key\"}}" &

  DELETE_COUNT=$((DELETE_COUNT + 1))
  # 控制并发，每 20 个等一下
  if [ $((DELETE_COUNT % 20)) -eq 0 ]; then
    wait
    printf "\r  已删除: %d" "$DELETE_COUNT"
  fi
done < <(printf '%s\n' "${SAMPLED_KEYS[@]}" && \
  aws dynamodb scan \
    --table-name "$TABLE_NAME" \
    --region "$REGION" \
    --filter-expression "begins_with(api_key, :prefix)" \
    --expression-attribute-values "{\":prefix\":{\"S\":\"sk-test-\"}}" \
    --projection-expression "api_key" \
    --query 'Items[].api_key.S' \
    --output text | tr '\t' '\n')

wait
echo ""
echo -e "  ${GREEN}✓ 清理完成${NC}"

# ====================================================================
# 汇总报告
# ====================================================================
log_section "测试报告"

TOTAL_COUNT=$((TOTAL_TESTS))
SUCCESS_RATE=$(python3 -c "print(f'{$PASSED_TESTS * 100 / $TOTAL_TESTS:.1f}' if $TOTAL_TESTS > 0 else '0')")

echo ""
echo "  测试规模:  ${SAMPLE_SIZE} keys × ${#MODELS[@]} models = ${TOTAL_TESTS} 次调用"
echo -e "  ${GREEN}通过:      ${PASSED_TESTS}${NC}"
echo -e "  ${RED}失败:      ${FAILED_TESTS}${NC}"
echo "  成功率:    ${SUCCESS_RATE}%"
echo ""

if [ "$FAILED_TESTS" -eq 0 ]; then
  echo -e "${GREEN}✓ 全部通过 — DynamoDB key 认证 + 全模型调用均正常${NC}"
  exit 0
else
  echo -e "${RED}✗ 有 ${FAILED_TESTS} 次失败${NC}"
  exit 1
fi
