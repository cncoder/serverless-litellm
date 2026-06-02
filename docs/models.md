# 模型配置

## 可用模型列表

| 模型名 | Bedrock Model ID | 区域类型 | 备注 |
|--------|-----------------|---------|------|
| `claude-opus-4-7-us` | `us.anthropic.claude-opus-4-7` | us | **新** |
| `claude-opus-4-7-global` | `global.anthropic.claude-opus-4-7` | global | **新** |
| `claude-opus-4-7` | `us.anthropic.claude-opus-4-7` | us | Claude Code 默认别名 **新** |
| `claude-opus-4-6-us` | `us.anthropic.claude-opus-4-6-v1` | us | |
| `claude-opus-4-6-global` | `global.anthropic.claude-opus-4-6-v1` | global | |
| `claude-opus-4-5` | `global.anthropic.claude-opus-4-5-20251101-v1:0` | global | |
| `claude-opus-4-1` | `us.anthropic.claude-opus-4-1-20250805-v1:0` | us | |
| `claude-sonnet-4-6-us` | `us.anthropic.claude-sonnet-4-6` | us | |
| `claude-sonnet-4-6-global` | `global.anthropic.claude-sonnet-4-6` | global | |
| `claude-opus-4-6` | `us.anthropic.claude-opus-4-6-v1` | us | Claude Code 默认别名 |
| `claude-sonnet-4-6` | `us.anthropic.claude-sonnet-4-6` | us | Claude Code 默认别名 |
| `claude-haiku-4-5-20251001` | `global.anthropic.claude-haiku-4-5-20251001-v1:0` | global | Claude Code 默认别名 |
| `claude-sonnet-4-5` | `global.anthropic.claude-sonnet-4-5-20250929-v1:0` | global | |
| `claude-sonnet-3-7` | `us.anthropic.claude-3-7-sonnet-20250219-v1:0` | us | |
| `claude-haiku-4-5` | `global.anthropic.claude-haiku-4-5-20251001-v1:0` | global | |
| `bedrock/*` | 任意 Bedrock 模型 ID | 通配符（直接透传）| |
| `gpt-5.5` | `openai.gpt-5.5` | us-east-2 (Mantle) | **新** OpenAI GPT-5.5 via Bedrock Mantle |
| `gpt-5.4` | `openai.gpt-5.4` | us-east-2 (Mantle) | **新** OpenAI GPT-5.4 via Bedrock Mantle |

**区域类型说明**:
- **us** - Cross-Region Inference 端点，us-west-2 和 us-east-1 自动负载均衡
- **global** - Global Inference 端点，跨多个区域全球负载均衡



---

## OpenAI GPT 模型（Bedrock Mantle）

2026-06-01 GA，OpenAI GPT-5.5 和 GPT-5.4 通过 Amazon Bedrock Mantle 提供服务。

| 模型名 | Model ID | 特点 |
|--------|----------|------|
| `gpt-5.5` | `openai.gpt-5.5` | 最强推理能力，支持 reasoning (high/medium/low) |
| `gpt-5.4` | `openai.gpt-5.4` | 性价比优选，适合日常任务 |

**注意事项**：
- 这些模型仅支持 **Responses API** (`/v1/responses`)，不支持 `/chat/completions`
- Endpoint: `https://bedrock-mantle.{region}.api.aws/openai/v1/responses`
- 认证方式：**AWS SigV4**（与其他 Bedrock 模型一致，IRSA 自动签名）
- 不支持的 tool types：`computer_use_preview`、`web_search`
- 支持的 tool types：`function`、`mcp`、`custom`、`namespace`、`tool_search`
- 需要 litellm >= 1.83.14（Docker 镜像已满足）

**通过 LiteLLM 调用**：
```python
import litellm
import os
os.environ['AWS_REGION_NAME'] = 'us-east-2'

# LiteLLM >= 1.83.14 原生支持
response = litellm.responses(
    model="bedrock/mantle/openai.gpt-5.5",
    input="Your prompt here",
)
```

**参考**：[AWS Blog - Get started with OpenAI GPT-5.5, GPT-5.4 models, and Codex on Amazon Bedrock](https://aws.amazon.com/blogs/aws/get-started-with-openai-gpt-5-5-gpt-5-4-models-and-codex-on-amazon-bedrock/)
---

## Fallback 降级链

```
claude-opus-4-7-us
  └─失败(3次)→ claude-opus-4-7-global
                └─失败(3次)→ claude-opus-4-6-us
                              └─失败(3次)→ claude-opus-4-6-global
                                            └─失败(3次)→ claude-opus-4-1

claude-opus-4-6-us
  └─失败(3次)→ claude-opus-4-6-global
                └─失败(3次)→ claude-opus-4-1
                              └─失败(3次)→ claude-opus-4-5
                              └─失败(3次)→ claude-sonnet-4-6-us
                                            └─失败(3次)→ claude-sonnet-4-6-global
                                                          └─失败(3次)→ claude-sonnet-4-5
                                                                        └─失败(3次)→ claude-sonnet-3-7
                                                                                      └─失败(3次)→ claude-sonnet-3-7
                                                                                                        └─失败(3次)→ claude-sonnet-4-6-us (回环兜底)

claude-haiku-4-5
  └─失败(3次)→ claude-sonnet-4-6-us (兜底)
```

**Fallback 参数**:
- `allowed_fails: 3` - 连续失败 3 次后标记不健康
- `cooldown_time: 60s` - 冷却 60 秒后重新启用
- `num_retries: 2` - 路由层自动重试 2 次
- `timeout: 600s` - 单次请求超时 10 分钟

---

## 通配符路由

直接调用任意 Bedrock 模型，绕过 Fallback 链：

```bash
curl -X POST https://litellm.example.com/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bedrock/us.anthropic.claude-opus-4-6-v1",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

---

## 路由策略

本项目使用 `simple-shuffle` 策略（等概率随机选择部署）。

其他可选策略（需要 Redis）：

| 策略 | 说明 |
|------|------|
| `latency-based-routing` | 优先路由到响应最快的部署 |
| `least-busy` | 优先路由到当前负载最低的部署 |
| `cost-based-routing` | 优先选择价格最低的模型 |

在 `kubernetes/configmap.yaml` 的 `router_settings` 中修改。
