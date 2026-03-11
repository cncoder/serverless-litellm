#!/bin/bash
# Usage: ./test-models.sh [BASE_URL] [API_KEY]
# Or: API_KEY=sk-xxx ./test-models.sh https://api.example.com

BASE_URL="${1:-${LITELLM_URL:-https://litellm.example.com}}"
API_KEY="${2:-${API_KEY:-${LITELLM_MASTER_KEY:-}}}"

if [ -z "$API_KEY" ] || [ "$API_KEY" = "<YOUR_API_KEY>" ]; then
  echo "错误: 请提供 API_KEY"
  echo "用法: API_KEY=sk-xxx $0"
  echo "或: $0 [BASE_URL] [API_KEY]"
  exit 1
fi

PROMPT_EN="What model are you? Answer in one sentence."
PROMPT_ZH="你是什么模型？一句话回答"

MODELS=(
  "claude-opus-4-6-us"
  "claude-opus-4-6-global"
  "claude-opus-4-5"
  "claude-sonnet-4-6-us"
  "claude-sonnet-4-6-global"
  "claude-sonnet-4-5"
  "claude-sonnet-3-7"
  "claude-sonnet-4-6"
  "claude-haiku-4-5"
)

# 注意：模型列表与 kubernetes/configmap.yaml 保持一致

SEP="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

call_model() {
  local model="$1"
  local prompt="$2"
  curl -sk \
    -X POST "$BASE_URL/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}]}" \
    -o /tmp/_model_body.json -w "%{http_code} %{time_total}" 2>&1
}

parse_response() {
  local stat="$1"
  local http_code time content error
  http_code=$(echo "$stat" | awk '{print $1}')
  time=$(echo "$stat" | awk '{printf "%.2f", $2}')
  if [ "$http_code" = "200" ]; then
    content=$(python3 -c "
import json,sys
d=json.load(open('/tmp/_model_body.json'))
print(d['choices'][0]['message']['content'].strip())
" 2>/dev/null)
    echo "OK|$time|$content"
  else
    error=$(python3 -c "
import json,sys
d=json.load(open('/tmp/_model_body.json'))
print(d.get('error',{}).get('message','unknown error'))
" 2>/dev/null || cat /tmp/_model_body.json | head -c 120)
    echo "FAIL|$time|HTTP $http_code - $error"
  fi
}

echo ""
echo "$SEP"
printf "  LiteLLM 模型测试\n"
printf "  时间: $(date '+%Y-%m-%d %H:%M:%S')    URL: $BASE_URL\n"
echo "$SEP"
printf "  提示词 (EN): %s\n" "$PROMPT_EN"
printf "  提示词 (ZH): %s\n" "$PROMPT_ZH"
echo "$SEP"
echo ""

PASS=0
FAIL=0
IDX=0

for MODEL in "${MODELS[@]}"; do
  IDX=$((IDX + 1))
  printf "  [%d/%d] %s\n" "$IDX" "${#MODELS[@]}" "$MODEL"

  # English
  STAT=$(call_model "$MODEL" "$PROMPT_EN")
  PARSED=$(parse_response "$STAT")
  STATUS=$(echo "$PARSED" | cut -d'|' -f1)
  TIME=$(echo "$PARSED" | cut -d'|' -f2)
  RESP=$(echo "$PARSED" | cut -d'|' -f3-)

  if [ "$STATUS" = "OK" ]; then
    printf "    EN  [OK]   %ss  %s\n" "$TIME" "$RESP"
  else
    printf "    EN  [FAIL] %ss  %s\n" "$TIME" "$RESP"
  fi

  # Chinese
  STAT=$(call_model "$MODEL" "$PROMPT_ZH")
  PARSED=$(parse_response "$STAT")
  STATUS=$(echo "$PARSED" | cut -d'|' -f1)
  TIME=$(echo "$PARSED" | cut -d'|' -f2)
  RESP=$(echo "$PARSED" | cut -d'|' -f3-)

  if [ "$STATUS" = "OK" ]; then
    printf "    ZH  [OK]   %ss  %s\n" "$TIME" "$RESP"
    PASS=$((PASS + 1))
  else
    printf "    ZH  [FAIL] %ss  %s\n" "$TIME" "$RESP"
    FAIL=$((FAIL + 1))
  fi

  echo ""
done

echo "$SEP"
printf "  结果汇总: %d 个模型  " "${#MODELS[@]}"
printf "通过 %d  " "$PASS"
printf "失败 %d\n" "$FAIL"
echo "$SEP"
echo ""
