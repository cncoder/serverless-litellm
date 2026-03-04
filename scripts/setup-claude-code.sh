#!/usr/bin/env bash
# 配置 Claude Code 使用 LiteLLM 代理
# 用法: ./scripts/setup-claude-code.sh [--host <url>] [--key <api_key>]

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${CYAN}ℹ${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*"; exit 1; }

LITELLM_HOST=""
API_KEY=""

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) LITELLM_HOST="$2"; shift 2 ;;
        --key)  API_KEY="$2";      shift 2 ;;
        *) shift ;;
    esac
done

# 自动从 Terraform output 读取
if [[ -z "$LITELLM_HOST" && -d "terraform" ]]; then
    info "从 Terraform output 读取配置..."
    cd terraform
    LITELLM_HOST=$(terraform output -raw litellm_host 2>/dev/null || echo "")
    cd ..
fi

# 交互式输入
if [[ -z "$LITELLM_HOST" ]]; then
    read -rp "LiteLLM 地址 (如 https://litellm.example.com): " LITELLM_HOST
fi

# 去掉末尾斜杠
LITELLM_HOST="${LITELLM_HOST%/}"

if [[ -z "$API_KEY" ]]; then
    read -rp "API Key (sk-xxx，留空则自动创建): " API_KEY
fi

# 如果未提供 Key，自动创建
if [[ -z "$API_KEY" ]]; then
    info "自动创建 API Key..."
    error "请先通过 LiteLLM Admin UI (/ui) 创建 API Key，然后运行: ./scripts/setup-claude-code.sh --key <sk-xxx>"
fi

ANTHROPIC_BASE_URL="${LITELLM_HOST}/anthropic"

echo ""
info "配置信息:"
echo -e "  ${CYAN}LiteLLM URL:${NC} ${LITELLM_HOST}"
echo -e "  ${CYAN}Anthropic Base URL:${NC} ${ANTHROPIC_BASE_URL}"
echo -e "  ${CYAN}API Key:${NC} ${API_KEY:0:12}..."
echo ""

# 写入 ~/.claude.json
CLAUDE_JSON="$HOME/.claude.json"

if [[ -f "$CLAUDE_JSON" ]]; then
    warn "已存在 $CLAUDE_JSON，备份到 ${CLAUDE_JSON}.bak"
    cp "$CLAUDE_JSON" "${CLAUDE_JSON}.bak"
fi

cat > "$CLAUDE_JSON" <<EOF
{
  "primaryProvider": "anthropic",
  "anthropicApiKey": "${API_KEY}",
  "anthropicBaseUrl": "${ANTHROPIC_BASE_URL}"
}
EOF

success "写入 ~/.claude.json"

# 输出环境变量（供 shell 配置文件使用）
SHELL_CONFIG=""
if [[ -f "$HOME/.zshrc" ]]; then
    SHELL_CONFIG="$HOME/.zshrc"
elif [[ -f "$HOME/.bashrc" ]]; then
    SHELL_CONFIG="$HOME/.bashrc"
fi

echo ""
info "环境变量（添加到 shell 配置文件）:"
echo ""
echo "  export ANTHROPIC_BASE_URL=\"${ANTHROPIC_BASE_URL}\""
echo "  export ANTHROPIC_AUTH_TOKEN=\"${API_KEY}\""
echo ""

if [[ -n "$SHELL_CONFIG" ]]; then
    read -rp "自动写入 $SHELL_CONFIG？(y/n) " -n 1
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cat >> "$SHELL_CONFIG" <<EOF

# LiteLLM for Claude Code (added by setup-claude-code.sh)
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL}"
export ANTHROPIC_AUTH_TOKEN="${API_KEY}"
EOF
        success "已写入 $SHELL_CONFIG"
        warn "请运行: source $SHELL_CONFIG"
    fi
fi

echo ""
success "配置完成！现在可以运行 claude"
echo ""
echo "  常用命令:"
echo "  claude                              # 启动 Claude Code"
echo "  claude --model claude-sonnet-4-5-20250929"
echo "  claude --model 'claude-sonnet-4-5-20250929[1m]'  # 1M context"
echo ""
