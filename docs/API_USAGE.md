# LiteLLM API 使用指南

## 基础信息

| 配置项 | 值 |
|-------|---|
| API Base URL | `https://litellm.example.com` |
| 认证方式 | Bearer Token (LiteLLM Native Auth) |
| API Key 存储 | RDS PostgreSQL |
| Key 创建方式 | LiteLLM Admin UI (`/ui`) |

---

## 可用模型

| 模型名称 | 端点 | 用途 |
|---------|------|------|
| `claude-opus-4-6-us` | us | 最强，us 端点 |
| `claude-opus-4-6-global` | global | 最强，global 端点 |
| `claude-opus-4-6` | us | Opus 4.6 兼容别名 |
| `claude-opus-4-5` | global | 次强 |
| `claude-sonnet-4-6-us` | us | 最新 Sonnet，us 端点 |
| `claude-sonnet-4-6-global` | global | 最新 Sonnet，global 端点 |
| `claude-sonnet-4-6` | us | Sonnet 4.6 兼容别名 |
| `claude-sonnet-4-5` | global | 平衡性能与成本 |
| `claude-sonnet-3-7` | us | 性价比高 |
| `claude-sonnet-3-5` | us | 快速响应 |
| `claude-haiku-4-5` | global | 最快最便宜 |

---

## 1. cURL 调用

### Chat Completions

```bash
curl -X POST https://litellm.example.com/v1/chat/completions \
  -H "Authorization: Bearer <YOUR_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-5",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 1000
  }'
```

**注意**: `<YOUR_API_KEY>` 是通过 LiteLLM Admin UI (`/ui`) 创建的 API Key (sk-xxx 格式)。

### Streaming

```bash
curl -X POST https://litellm.example.com/v1/chat/completions \
  -H "Authorization: Bearer <YOUR_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-5",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 1000,
    "stream": true
  }'
```

### 列出模型

```bash
curl https://litellm.example.com/v1/models \
  -H "Authorization: Bearer <YOUR_API_KEY>"
```

---

## 2. Python (OpenAI SDK)

### 安装

```bash
pip install openai
```

### 基本调用

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://litellm.example.com/v1",
    api_key="<YOUR_API_KEY>"
)

response = client.chat.completions.create(
    model="claude-sonnet-4-5",
    messages=[{"role": "user", "content": "Hello"}],
    max_tokens=1000
)
print(response.choices[0].message.content)
```

### Streaming

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://litellm.example.com/v1",
    api_key="<YOUR_API_KEY>"
)

stream = client.chat.completions.create(
    model="claude-sonnet-4-5",
    messages=[{"role": "user", "content": "Write a poem"}],
    max_tokens=500,
    stream=True
)

for chunk in stream:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="")
```

### 多轮对话

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://litellm.example.com/v1",
    api_key="<YOUR_API_KEY>"
)

messages = [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "What is Python?"}
]

response = client.chat.completions.create(
    model="claude-sonnet-4-5",
    messages=messages,
    max_tokens=1000
)

# 添加助手回复到历史
messages.append({"role": "assistant", "content": response.choices[0].message.content})

# 继续对话
messages.append({"role": "user", "content": "Show me an example"})

response = client.chat.completions.create(
    model="claude-sonnet-4-5",
    messages=messages,
    max_tokens=1000
)
print(response.choices[0].message.content)
```

---

## 3. Python (Anthropic SDK)

### 安装

```bash
pip install anthropic
```

### 基本调用

```python
import anthropic

client = anthropic.Anthropic(
    base_url="https://litellm.example.com",
    api_key="<YOUR_API_KEY>"
)

message = client.messages.create(
    model="claude-sonnet-4-5",
    max_tokens=1000,
    messages=[{"role": "user", "content": "Hello"}]
)
print(message.content[0].text)
```

### Streaming

```python
import anthropic

client = anthropic.Anthropic(
    base_url="https://litellm.example.com",
    api_key="<YOUR_API_KEY>"
)

with client.messages.stream(
    model="claude-sonnet-4-5",
    max_tokens=1000,
    messages=[{"role": "user", "content": "Hello"}]
) as stream:
    for text in stream.text_stream:
        print(text, end="")
```

---

## 4. Node.js (OpenAI SDK)

### 安装

```bash
npm install openai
```

### 基本调用

```javascript
import OpenAI from 'openai';

const client = new OpenAI({
  baseURL: 'https://litellm.example.com/v1',
  apiKey: '<YOUR_API_KEY>'
});

async function main() {
  const response = await client.chat.completions.create({
    model: 'claude-sonnet-4-5',
    messages: [{ role: 'user', content: 'Hello' }],
    max_tokens: 1000
  });
  console.log(response.choices[0].message.content);
}

main();
```

### Streaming

```javascript
import OpenAI from 'openai';

const client = new OpenAI({
  baseURL: 'https://litellm.example.com/v1',
  apiKey: '<YOUR_API_KEY>'
});

async function main() {
  const stream = await client.chat.completions.create({
    model: 'claude-sonnet-4-5',
    messages: [{ role: 'user', content: 'Hello' }],
    max_tokens: 1000,
    stream: true
  });

  for await (const chunk of stream) {
    process.stdout.write(chunk.choices[0]?.delta?.content || '');
  }
}

main();
```

---

## 5. 环境变量配置

### OpenAI SDK 兼容

```bash
export OPENAI_API_BASE="https://litellm.example.com/v1"
export OPENAI_API_KEY="<YOUR_API_KEY>"
```

### Anthropic SDK 兼容

```bash
export ANTHROPIC_BASE_URL="https://litellm.example.com/"
export ANTHROPIC_API_KEY="<YOUR_API_KEY>"
```

### Claude Code 配置

`~/.claude/settings.json`:

```json
{
  "apiKeyHelper": "echo <YOUR_API_KEY>",
  "primaryProvider": "anthropic"
}

```

环境变量:

```bash
export ANTHROPIC_BASE_URL="https://litellm.example.com/"
```

---

## 6. 健康检查

```bash
# Liveness
curl https://litellm.example.com/health/liveliness

# Readiness
curl https://litellm.example.com/health/readiness
```

---

## 7. Fallback 降级策略

当主模型不可用时，自动降级到备选模型：

- `claude-opus-4-6-us` -> `claude-opus-4-6-global` -> `claude-opus-4-5` -> `claude-sonnet-4-6-us` -> `claude-sonnet-4-6-global` -> `claude-sonnet-4-5`
- `claude-sonnet-4-5` -> `claude-sonnet-3-7` -> `claude-sonnet-3-5`
- `claude-haiku-4-5` -> `claude-sonnet-3-5`
