# OpenClaw / Hermes 接入 LiteLLM 网关

两者都走 OpenAI 兼容的 `/v1/chat/completions`，配置一致：指向网关 base_url + master key。

## 环境变量方式（通用 OpenAI SDK / Hermes）

```bash
export OPENAI_BASE_URL="https://<cloudfront-domain>/v1"
export OPENAI_API_KEY="<master-key>"
# 模型名用网关短名：opus-4-8 / sonnet-4-6 / gpt-5.6-terra ...
```

## OpenClaw 模型配置

```jsonc
{
  "provider": "openai",
  "base_url": "https://<cloudfront-domain>/v1",
  "api_key": "<master-key>",
  "model": "opus-4-8"
}
```

## Python OpenAI SDK 示例

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://<cloudfront-domain>/v1",
    api_key="<master-key>",
)

# Claude（chat completions）
r = client.chat.completions.create(
    model="opus-4-8",
    messages=[{"role": "user", "content": "hello"}],
)
print(r.choices[0].message.content)

# GPT（chat completions，网关内部转 Responses）
r = client.chat.completions.create(
    model="gpt-5.6-terra",
    messages=[{"role": "user", "content": "hello"}],
)
```

## 多模态（图片输入）

```python
r = client.chat.completions.create(
    model="opus-4-8",
    messages=[{"role": "user", "content": [
        {"type": "text", "text": "描述这张图"},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64,<BASE64>"}},
    ]}],
)
```

> 实测：Claude 系（opus-4-8/fable-5/opus-4-6/sonnet-4-6）与 GPT 系（gpt-5.6-*）经 `/v1/chat/completions` 均通；多模态图片经 Converse 识别正常。
