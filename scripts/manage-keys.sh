#!/usr/bin/env bash

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 打印函数
info() { echo -e "${BLUE}ℹ${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*"; }

# 获取配置
get_config() {
    # 优先从环境变量读取
    if [[ -n "${AWS_REGION:-}" && -n "${DYNAMODB_API_KEYS_TABLE:-}" ]]; then
        REGION="$AWS_REGION"
        TABLE_NAME="$DYNAMODB_API_KEYS_TABLE"
        return
    fi

    # 从 terraform output 读取
    if [[ -d "terraform" ]]; then
        cd terraform
        REGION=$(terraform output -raw aws_region 2>/dev/null || echo "")
        TABLE_NAME=$(terraform output -raw dynamodb_table_name 2>/dev/null || echo "")
        cd ..
    else
        REGION=""
        TABLE_NAME=""
    fi

    if [[ -z "$REGION" || -z "$TABLE_NAME" ]]; then
        error "无法获取配置信息"
        echo "请设置环境变量："
        echo "  export AWS_REGION=<region>"
        echo "  export DYNAMODB_API_KEYS_TABLE=<table-name>"
        echo "或在 terraform 目录运行 terraform output"
        exit 1
    fi
}

# 生成 API key
generate_api_key() {
    local user_id="$1"
    local random_suffix
    random_suffix=$(openssl rand -hex 12)
    echo "sk-${user_id}-${random_suffix}"
}

# 添加新 key
add_key() {
    local user_id="$1"
    local budget="${2:-0}"

    if [[ -z "$user_id" ]]; then
        error "user_id 不能为空"
        exit 1
    fi

    local api_key
    api_key=$(generate_api_key "$user_id")
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    info "创建新 API key..."
    echo -e "${CYAN}User ID:${NC} $user_id"
    echo -e "${CYAN}Budget:${NC} $budget"
    echo -e "${CYAN}API Key:${NC} $api_key"
    echo ""

    read -p "确认创建？ (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "已取消"
        exit 0
    fi

    aws dynamodb put-item \
        --region "$REGION" \
        --table-name "$TABLE_NAME" \
        --item "{
            \"api_key\": {\"S\": \"$api_key\"},
            \"user_id\": {\"S\": \"$user_id\"},
            \"enabled\": {\"BOOL\": true},
            \"max_budget\": {\"N\": \"$budget\"},
            \"spend\": {\"N\": \"0\"},
            \"created_at\": {\"S\": \"$timestamp\"}
        }" \
        --return-consumed-capacity TOTAL >/dev/null

    success "API key 创建成功"
    echo ""
    echo -e "${GREEN}API Key:${NC} ${CYAN}$api_key${NC}"
    echo -e "${YELLOW}请妥善保管，此 key 不会再次显示${NC}"
}

# 列出所有 key
list_keys() {
    info "获取所有 API keys..."

    local output
    output=$(aws dynamodb scan \
        --region "$REGION" \
        --table-name "$TABLE_NAME" \
        --output json)

    local count
    count=$(echo "$output" | jq -r '.Count')

    if [[ "$count" -eq 0 ]]; then
        warn "未找到任何 API key"
        exit 0
    fi

    echo ""
    printf "${CYAN}%-40s %-20s %-10s %-12s %-12s${NC}\n" "API Key" "User ID" "Enabled" "Budget" "Spend"
    echo "──────────────────────────────────────────────────────────────────────────────────────────────"

    echo "$output" | jq -r '.Items[] | [
        .api_key.S,
        .user_id.S,
        .enabled.BOOL,
        .max_budget.N,
        .spend.N
    ] | @tsv' | while IFS=$'\t' read -r api_key user_id enabled budget spend; do
        local enabled_display
        if [[ "$enabled" == "true" ]]; then
            enabled_display="${GREEN}✓${NC}"
        else
            enabled_display="${RED}✗${NC}"
        fi
        printf "%-40s %-20s %-10s %-12s %-12s\n" "$api_key" "$user_id" "$(echo -e "$enabled_display")" "$budget" "$spend"
    done

    echo ""
    success "共 $count 个 API key"
}

# 获取 key 详情
get_key() {
    local api_key="$1"

    if [[ -z "$api_key" ]]; then
        error "api_key 不能为空"
        exit 1
    fi

    info "查询 API key: $api_key"

    local output
    output=$(aws dynamodb get-item \
        --region "$REGION" \
        --table-name "$TABLE_NAME" \
        --key "{\"api_key\": {\"S\": \"$api_key\"}}" \
        --output json)

    if [[ $(echo "$output" | jq -r '.Item') == "null" ]]; then
        error "未找到该 API key"
        exit 1
    fi

    echo ""
    echo -e "${CYAN}API Key:${NC} $(echo "$output" | jq -r '.Item.api_key.S')"
    echo -e "${CYAN}User ID:${NC} $(echo "$output" | jq -r '.Item.user_id.S')"
    echo -e "${CYAN}Enabled:${NC} $(echo "$output" | jq -r '.Item.enabled.BOOL')"
    echo -e "${CYAN}Max Budget:${NC} $(echo "$output" | jq -r '.Item.max_budget.N')"
    echo -e "${CYAN}Spend:${NC} $(echo "$output" | jq -r '.Item.spend.N')"
    echo -e "${CYAN}Created At:${NC} $(echo "$output" | jq -r '.Item.created_at.S // "N/A"')"
}

# 禁用 key
disable_key() {
    local api_key="$1"

    if [[ -z "$api_key" ]]; then
        error "api_key 不能为空"
        exit 1
    fi

    info "禁用 API key: $api_key"
    read -p "确认禁用？ (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "已取消"
        exit 0
    fi

    aws dynamodb update-item \
        --region "$REGION" \
        --table-name "$TABLE_NAME" \
        --key "{\"api_key\": {\"S\": \"$api_key\"}}" \
        --update-expression "SET enabled = :val" \
        --expression-attribute-values '{":val": {"BOOL": false}}' \
        --return-values ALL_NEW \
        --output json >/dev/null

    success "API key 已禁用"
}

# 启用 key
enable_key() {
    local api_key="$1"

    if [[ -z "$api_key" ]]; then
        error "api_key 不能为空"
        exit 1
    fi

    info "启用 API key: $api_key"
    read -p "确认启用？ (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "已取消"
        exit 0
    fi

    aws dynamodb update-item \
        --region "$REGION" \
        --table-name "$TABLE_NAME" \
        --key "{\"api_key\": {\"S\": \"$api_key\"}}" \
        --update-expression "SET enabled = :val" \
        --expression-attribute-values '{":val": {"BOOL": true}}' \
        --return-values ALL_NEW \
        --output json >/dev/null

    success "API key 已启用"
}

# 删除 key
delete_key() {
    local api_key="$1"

    if [[ -z "$api_key" ]]; then
        error "api_key 不能为空"
        exit 1
    fi

    warn "删除 API key: $api_key"
    echo -e "${RED}此操作不可恢复！${NC}"
    read -p "确认删除？输入 'DELETE' 确认: " confirm

    if [[ "$confirm" != "DELETE" ]]; then
        warn "已取消"
        exit 0
    fi

    aws dynamodb delete-item \
        --region "$REGION" \
        --table-name "$TABLE_NAME" \
        --key "{\"api_key\": {\"S\": \"$api_key\"}}" \
        --output json >/dev/null

    success "API key 已删除"
}

# 显示帮助
show_help() {
    cat <<EOF
${CYAN}DynamoDB API Key 管理工具${NC}

${YELLOW}用法:${NC}
  $0 <command> [options]

${YELLOW}命令:${NC}
  ${GREEN}add${NC} <user_id> [--budget <amount>]   创建新 API key
  ${GREEN}list${NC}                                 列出所有用户
  ${GREEN}get${NC} <api_key>                        查看 key 详情
  ${GREEN}disable${NC} <api_key>                    禁用 key
  ${GREEN}enable${NC} <api_key>                     启用 key
  ${GREEN}delete${NC} <api_key>                     删除 key

${YELLOW}环境变量:${NC}
  AWS_REGION                  AWS 区域
  DYNAMODB_API_KEYS_TABLE     DynamoDB 表名

${YELLOW}示例:${NC}
  $0 add user123 --budget 100
  $0 list
  $0 get sk-user123-abc123
  $0 disable sk-user123-abc123
  $0 enable sk-user123-abc123
  $0 delete sk-user123-abc123
EOF
}

# 主函数
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi

    local command="$1"
    shift

    # 获取配置
    get_config

    case "$command" in
        add)
            local user_id="${1:-}"
            local budget="0"
            shift || true
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --budget)
                        budget="${2:-0}"
                        shift 2 || shift
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            add_key "$user_id" "$budget"
            ;;
        list)
            list_keys
            ;;
        get)
            get_key "${1:-}"
            ;;
        disable)
            disable_key "${1:-}"
            ;;
        enable)
            enable_key "${1:-}"
            ;;
        delete)
            delete_key "${1:-}"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "未知命令: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
