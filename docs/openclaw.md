# OpenClaw 配置指南

通过 [OpenClaw](https://github.com/openclaw/openclaw) 连接 LiteLLM，所有 AI 请求经由 AWS Bedrock 路由 — 无需 Anthropic API Key。

---

## OpenClaw 是什么？

OpenClaw 是一个开源 AI 助手框架，作为常驻守护进程运行，可连接 Discord、Telegram、Slack 等消息平台，提供文件操作、Shell 命令、浏览器自动化、定时任务等工具能力。

默认情况下 OpenClaw 直连 AI 服务商（Anthropic、OpenAI 等）。通过本指南的 LiteLLM 集成，所有 AI 请求将路由至你自建的 LiteLLM 代理 → AWS Bedrock：

- **无需 Anthropic API Key** — 直接使用 AWS Bedrock 访问权限
- **集中化用量追踪** — 所有 token 用量记录在 LiteLLM PostgreSQL 数据库
- **多模型路由** — 通过 LiteLLM 配置在 Opus、Sonnet、Haiku 间切换
- **自动故障转移** — LiteLLM fallback chain 自动处理模型不可用
- **成本控制** — 在 LiteLLM Admin UI 设置 per-key 预算和限流

---

## 前置条件

- 已部署的 LiteLLM 实例（参见 [主 README](../README.md)）
- LiteLLM 端点 URL（如 `https://litellm.example.com`）
- LiteLLM API Key（Master Key 或通过 Admin UI 创建的 Key）
- 已安装 OpenClaw（[安装指南](https://docs.openclaw.ai)）

---

## 快速开始

### 1. 安装 OpenClaw

```bash
# npm（需要 Node.js 20+）
npm install -g openclaw

# 验证
openclaw --version
```

### 2. 配置 LiteLLM 作为 AI 后端

编辑 `~/.openclaw/openclaw.json`：

```json
{
  "models": {
    "providers": {
      "litellm": {
        "baseUrl": "https://litellm.example.com/v1",
        "apiKey": "<your-litellm-key>",
        "api": "openai-completions",
        "models": [
          {
            "id": "claude-sonnet-4-6",
            "name": "Claude Sonnet 4.6",
            "contextWindow": 200000,
            "maxTokens": 16384
          },
          {
            "id": "claude-opus-4-6",
            "name": "Claude Opus 4.6",
            "contextWindow": 200000,
            "maxTokens": 16384
          },
          {
            "id": "claude-haiku-4-5",
            "name": "Claude Haiku 4.5",
            "contextWindow": 200000,
            "maxTokens": 16384
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": "litellm/claude-sonnet-4-6"
    }
  },
  "gateway": {
    "mode": "local"
  }
}
```

> **注意**：`baseUrl` 必须包含 `/v1` 后缀。模型引用格式为 `litellm/<model-id>`，其中 `litellm` 是 provider 名称。

### 3. 启动 Gateway

```bash
openclaw gateway start
```

---

## 可用模型

使用 LiteLLM 配置中定义的任意模型别名：

| 模型 | 适用场景 | 成本 |
|------|----------|------|
| `claude-opus-4-6` | 复杂推理、编码、深度分析 | $$$ |
| `claude-sonnet-4-6` | 通用任务，速度与质量均衡 | $$ |
| `claude-haiku-4-5` | 快速响应，简单任务 | $ |
| `claude-sonnet-4-5` | 上一代 Sonnet | $$ |

运行时切换模型：

```bash
# 或在聊天中使用命令
/model litellm/claude-opus-4-6
```

---

## 工作原理

```
用户 (Discord / Telegram / CLI)
    │
    ▼
OpenClaw Gateway
    │
    ▼  OpenAI 兼容 API（/v1/chat/completions）
LiteLLM Proxy
    │
    ▼
AWS Bedrock (Claude 模型)
```

OpenClaw 使用 OpenAI 兼容的 Chat Completions API，LiteLLM 原生支持并自动翻译为 Bedrock API 格式。

关键行为：
- **流式响应**：OpenClaw 默认使用 SSE 流式传输，LiteLLM 完整支持
- **工具调用**：OpenClaw 的 tool-use 功能通过 LiteLLM 无需修改即可工作
- **Token 追踪**：所有用量由 LiteLLM 记录，可在 Admin UI 查看
- **思考模式**：兼容模型（Opus、Sonnet）支持 extended thinking

---

## 验证集成

### 1. 检查 LiteLLM 健康状态

```bash
curl -s https://litellm.example.com/health/liveliness
# 预期: "I'm alive!"
```

### 2. 测试 API 连通性

```bash
curl -s https://litellm.example.com/v1/chat/completions \
  -H "Authorization: Bearer <your-litellm-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-6",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 50
  }'
```

### 3. 通过 OpenClaw 测试

```bash
openclaw agent --agent main --message "What is 2+2?"
# 预期输出: 4
```

### 4. 查看 Token 用量

访问 `https://litellm.example.com/ui` → 用 Master Key 登录 → Usage 面板。

---

## 在 EC2 上部署 OpenClaw + LiteLLM

```bash
# 在 EC2 实例上（Amazon Linux 2023 / Ubuntu 22.04）

# 1. 安装 Node.js
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh"
nvm install 22 && nvm use 22

# 2. 安装 OpenClaw
npm install -g openclaw

# 3. 写入配置（替换 <your-alb> 和 <your-key>）
mkdir -p ~/.openclaw
cat > ~/.openclaw/openclaw.json << 'EOF'
{
  "models": {
    "providers": {
      "litellm": {
        "baseUrl": "http://<your-alb>/v1",
        "apiKey": "<your-litellm-key>",
        "api": "openai-completions",
        "models": [
          { "id": "claude-sonnet-4-6", "name": "Claude Sonnet 4.6", "contextWindow": 200000, "maxTokens": 16384 }
        ]
      }
    }
  },
  "agents": { "defaults": { "model": "litellm/claude-sonnet-4-6" } },
  "gateway": { "mode": "local" }
}
EOF

# 4. 启动
openclaw gateway start
```

> **提示**：如果 LiteLLM 和 OpenClaw 在同一个 VPC，使用内部 ALB DNS（如 `http://internal-k8s-litellm-xxxx.elb.amazonaws.com`）可降低延迟和数据传输费用。

---

## 故障排查

### "Model not found" 错误

确保 `openclaw.json` 中的模型名称与 LiteLLM 配置中的别名匹配：

```bash
curl -s https://litellm.example.com/v1/models \
  -H "Authorization: Bearer <your-key>" | jq '.data[].id' | head -20
```

### 连接超时

- 确认 LiteLLM 可达：`curl -s https://litellm.example.com/health/liveliness`
- 检查安全组是否允许来自 OpenClaw 所在 IP/VPC 的流量
- 使用内部 ALB 时，确保 OpenClaw EC2 在同一 VPC 或已建立 VPC Peering

### 流式传输问题

OpenClaw 需要流式支持，验证方式：

```bash
curl -N https://litellm.example.com/v1/chat/completions \
  -H "Authorization: Bearer <your-key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"Hi"}],"max_tokens":10,"stream":true}'
```

应看到 `data: {...}` 数据块逐步到达。

---

## 远程桌面访问（NICE DCV）

OpenClaw 的部分配置需要 GUI 操作（如 Discord OAuth 授权、浏览器登录、Dashboard 管理）。在 headless EC2 上，推荐使用 [NICE DCV](https://aws.amazon.com/hpc/dcv/) 提供远程桌面：

```bash
# Amazon Linux 2023
sudo yum install -y nice-dcv-server nice-dcv-web-viewer
sudo systemctl enable --now dcvserver

# 创建 DCV session
dcv create-session --type virtual openclaw-session

# 从本地连接（浏览器或 DCV Client）
# https://<ec2-public-ip>:8443
```

**适用场景**：
- 首次初始化 OpenClaw（`openclaw setup` 交互式配置）
- 配置消息渠道（Discord Bot Token、Telegram Webhook 等需要浏览器操作）
- 访问 LiteLLM Admin UI（`https://<alb>/ui`）
- 调试 OpenClaw Dashboard（`http://127.0.0.1:18789`）

> **安全提示**：DCV 默认监听 8443 端口，安全组仅开放给你的 IP（`/32`），不要用 `0.0.0.0/0`。

参考：[AWS NICE DCV 远程桌面搭建指南](https://aws.amazon.com/jp/builders-flash/202407/nice-dcv-content-creation/)

---

## 安全建议

- **API Key 轮换**：通过 LiteLLM Admin UI 为每个 OpenClaw 实例创建独立 Key，泄露时可单独撤销
- **网络隔离**：将 OpenClaw 和 LiteLLM 部署在同一 VPC，使用内部 ALB 通信
- **预算限制**：在 LiteLLM 设置 per-key 消费上限，防止成本失控
- **审计追踪**：LiteLLM 记录所有请求的模型、token 数、成本和 Key 元数据

---

## 相关文档

- [OpenClaw 文档](https://docs.openclaw.ai) — 完整 OpenClaw 文档
- [OpenClaw GitHub](https://github.com/openclaw/openclaw) — 源码
- [LiteLLM 文档](https://docs.litellm.ai) — LiteLLM 代理文档
- [Claude Code 指南](claude-code.md) — Claude Code 配置
- [API 使用示例](API_USAGE.md) — 直接 API 调用示例
