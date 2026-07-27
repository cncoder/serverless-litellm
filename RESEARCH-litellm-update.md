# LiteLLM 部署调研报告

**调研日期**: 2026-07-27  
**目标**: serverless-litellm（Fargate + ALB + CloudFront）最小推理网关更新所需的官方配置信息  
**方法**: 多源网络查证，所有结论标来源 URL

---

## 开头：最小 config.yaml 骨架建议

基于各节官方文档确认的字段，供部署参考。标注了置信度。

```yaml
model_list:
  # Claude Code / Hermes / OpenClaw 走 Anthropic Messages 格式，指向这组 Bedrock 模型
  - model_name: "claude-sonnet-4-6"          # 【官方文档确认】model 格式
    litellm_params:
      model: "bedrock/us.anthropic.claude-sonnet-4-6"   # ⚠️ 具体 model ID 需 AWS API 实测
      aws_region_name: "us-east-1"
      custom_llm_provider: "bedrock"
  - model_name: "claude-opus-4-6"
    litellm_params:
      model: "bedrock/us.anthropic.claude-opus-4-6-v1"  # ⚠️ 需 AWS API 实测确认
      aws_region_name: "us-east-1"
      custom_llm_provider: "bedrock"

  # Codex 走 OpenAI Responses API，需要 openai provider + openai API key
  - model_name: "gpt-5.2-codex"              # 【待确认】具体模型名，见第5节
    litellm_params:
      model: "openai/gpt-5.2-codex"
      api_key: "os.environ/OPENAI_API_KEY"

litellm_settings:
  drop_params: true                           # 【官方文档确认】自动丢弃 Bedrock 不支持的参数

general_settings:
  master_key: "os.environ/LITELLM_MASTER_KEY" # 【官方文档确认】单 master key 认证

environment_variables:
  LITELLM_LOCAL_ANTHROPIC_BETA_HEADERS: "True" # 【官方文档确认】禁止远端拉取 beta headers 覆盖本地
```

**各接入方环境变量**：
- Claude Code: `ANTHROPIC_BASE_URL=https://<your-cf-domain>` + `ANTHROPIC_AUTH_TOKEN=<master-key>`
- Codex: `~/.codex/config.toml`，见第4节
- Hermes / OpenClaw: `OPENAI_BASE_URL=https://<your-cf-domain>/v1` + `OPENAI_API_KEY=<master-key>`

---

## 第1节 LiteLLM 最新稳定版本

**结论**: 截至 2026-07-27，GitHub releases 页显示最新 stable 版本为 **v1.93.0**（`v1.94.x` 系列处于 rc/dev 阶段）。Docker image tag 策略已于 2026 年 4 月底发生变化。

**Docker tag 说明**（官方已变更）：

| 旧 tag | 新 tag | 说明 |
|--------|--------|------|
| `main-stable` | **已弃用**（计划 2026-09-01 停止发布） | 历史上是"每周滚动稳定版"，仍在更新但官方不推荐 |
| `:latest` | **当前推荐的滚动稳定 tag** | 每周 stable 发布后自动更新 |
| `:1.93.0` | 推荐的可复现固定 tag | 生产环境用固定版本号 |

**版本命名规则**（2026-04-28 起生效）：
- MINOR 每周 bump：`1.84.0` → `1.85.0`
- PATCH 仅用于 hotfix：`1.84.0` → `1.84.1`
- `v` 前缀可选：`ghcr.io/berriai/litellm:1.93.0` 和 `:v1.93.0` 指向同一镜像

**建议**: 现有 Dockerfile 用的 `main-stable` 仍然工作但应迁移到 `:latest`（滚动）或固定版本号（生产推荐）。

**来源**:
- https://docs.litellm.ai/blog/cleaner-release-versions（2026-04-28，Last Updated: July 2026）
- https://github.com/BerriAI/litellm/releases（releases 列表，查证日期 2026-07-27）

---

## 第2节 Bedrock Claude 模型官方配置方式

**结论**: 官方文档确认的字段格式如下。

**model 字段标准格式**：

```
bedrock/<inference-profile-id>
```

具体例子（来自官方 docs 和 tutorial，注意：具体 ID 随时间变化，需 AWS API 实测）：

```yaml
model: "bedrock/us.anthropic.claude-3-5-sonnet-20240620-v1:0"    # 官方文档示例
model: "bedrock/us.anthropic.claude-sonnet-4-20250514-v1:0"       # Claude Agent SDK tutorial
model: "bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0"     # Claude Agent SDK tutorial
model: "bedrock/us.anthropic.claude-opus-4-5-20251101-v1:0"       # Claude Agent SDK tutorial
```

**关于三种路由前缀的区别**：
- `bedrock/<model-id>` — 标准路由，走 Bedrock Converse API（推荐，支持全部功能）
- `bedrock/converse/<model-id>` — 等价于 `bedrock/`，显式指定 Converse API
- `bedrock/invoke/<model-id>` — 走 Bedrock InvokeModel API（旧 API，新部署不推荐）
- `bedrock/converse/<ARN>` — 用于 Application Inference Profile ARN（不能用 `bedrock/<ARN>`）

**通配符支持**: 官方文档未提到 `bedrock/*` 通配符，不应假设支持。

**aws_region_name**: 直接在 litellm_params 下写，值为 region 字符串如 `"us-east-1"`。环境变量也可用 `AWS_REGION_NAME`。

**⚠️ 注意**: 不能在 litellm_params 里加 `api_key`，加了会破坏 AWS 凭证链（IAM Role 将失效）。

**来源**:
- https://docs.litellm.ai/docs/bedrock_converse（官方 Bedrock Converse 配置页）
- https://docs.litellm.ai/docs/bedrock_invoke（官方 Bedrock Invoke 配置页）
- https://docs.litellm.ai/docs/tutorials/claude_agent_sdk（Claude Agent SDK tutorial，含 claude-sonnet-4 系列 ID）
- https://mrkaran.dev/posts/litellm-bedrock-setup/（2026-02-16，Application Inference Profile ARN 需用 bedrock/converse/ 前缀）

**待确认**: Opus 4.8 / Fable 5（Fable 5 = Claude 3.5 Haiku?）的精确 inference profile ID，运行 `aws bedrock list-inference-profiles` 实测。

---

## 第3节 anthropic beta headers 问题

**结论**: 这个问题在 LiteLLM **v1.81.13-nightly 已官方修复**，不再需要改源码的 patch。当前 Dockerfile 的 patch 方法可被官方配置替代。

### Issue 号核实

现有 Dockerfile 里引用的 `#49238` 号码未能通过搜索直接确认其确切标题，但官方 Incident Report 确认：
- **事件日期**: 2026-02-13，持续约 3 小时，Severity: High
- **修复版本**: v1.81.13-nightly 及以上
- 相关 issue 包含 `BerriAI/litellm#24518`（在 Anthropic 官方文档中引用）和 `BerriAI/litellm#21912`/`#21913`（context_management 未修复版本）

**根本原因**: LiteLLM 在 v1.81 之前将所有 anthropic-beta headers 无差别转发给所有 provider，Bedrock 收到不支持的 header 返回 400 "invalid beta flag"。

**官方修复机制**: 引入了 `anthropic_beta_headers_config.json`，按 provider 映射哪些 beta header 是 null（丢弃）、哪些传递。

**官方推荐配置方式**（无需改源码）：

方式一：使用环境变量 `LITELLM_LOCAL_ANTHROPIC_BETA_HEADERS=True`（现有 Dockerfile 已用此变量），配合保持本地 config 文件不被远端覆盖。这是正确做法。

方式二：设置 `LITELLM_ANTHROPIC_BETA_HEADERS_URL` 指向自己托管的 config JSON，动态更新不需要重启。

方式三：调用 `/reload/anthropic_beta_headers` API endpoint 热更新（无重启）。

**当前 Dockerfile patch 的评估**:
- 修改 `anthropic_beta_headers_config.json` 文件本身在官方文档里是**推荐的贡献方式**，属于官方配置手段，不是 hack。
- 但从 v1.81.13 起，LiteLLM 的默认 config 文件里已经包含了大多数已知需要 null 的 headers。
- 问题：新版本可能新增了更多需要过滤的 header（如 `tmp-preserve-thinking-2025-10-01`，见 issue #335），patch 仅修了旧问题。
- **推荐**: 升级到 `>=v1.93.0`，设置 `LITELLM_LOCAL_ANTHROPIC_BETA_HEADERS=True`（已在 Dockerfile 里），**不再需要 RUN python3 patch 那段**。LiteLLM 最新内置的 config 已覆盖 interleaved-thinking 和 context-management，直接用即可。若仍有问题再加 context_management Bedrock 支持需配合 `drop_params: true`。

**来源**:
- https://docs.litellm.ai/blog/claude-code-beta-headers-incident（官方 Incident Report，2026-02-16）
- https://docs.litellm.ai/docs/tutorials/claude_code_beta_headers（官方 beta headers 管理指南）
- https://github.com/BerriAI/litellm/issues/21913/linked_closing_reference（context_management 在 v1.81.x 的 issue）
- https://github.com/anthropics/claude-agent-sdk-python/issues/335（tmp-preserve-thinking 问题，2025-11）

---

## 第4节 Codex 接入 OpenAI 兼容 gateway

**结论**: Codex CLI 使用 `~/.codex/config.toml` 配置自定义 provider，**默认走 `/v1/responses`（OpenAI Responses API）**，不是 `/v1/chat/completions`。`wire_api` 字段在 v0.138+ 默认就是 `"responses"`，设置 `"chat"` 会导致启动崩溃。

**标准配置结构**：

```toml
# ~/.codex/config.toml

model          = "gpt-5.2-codex"      # 模型名，见第5节
model_provider = "litellm-gateway"    # 对应下方 [model_providers.litellm-gateway]

[model_providers.litellm-gateway]
name     = "LiteLLM Gateway"
base_url = "https://<your-cf-domain>/v1"  # Codex 会在此基础上拼接 /responses
env_key  = "LITELLM_API_KEY"              # 读这个环境变量作为 Bearer token
wire_api = "responses"                     # 默认值，可省略；但第三方需要 "chat" 时要显式写
```

**关键细节**:
- `base_url` 末尾是 `/v1`，**不要**加 `/responses`，Codex 会自动拼接
- `env_key` 指定读哪个环境变量，API 密钥不写在 config 文件里
- `wire_api = "responses"` 表示 Codex 调 `{base_url}/responses` 端点
- 第三方兼容 gateway 如果只支持 `/chat/completions`，需要改 `wire_api = "chat"`

**LiteLLM 的 /v1/responses 支持**（见第6节）: LiteLLM 已原生支持 `/v1/responses`（OpenAI Responses API 格式），内部会转换到对应 provider。

**如果想把 Codex 路由到 Bedrock Claude**（而不是 OpenAI）：LiteLLM 的 `/v1/responses` 接受 `model: "bedrock/..."` 或 `model: "claude-sonnet-4-6"`（model_list 里定义的别名），因此可以把 Codex 的 model 设成你的 Bedrock 别名，让 LiteLLM 转发到 Bedrock。

**来源**:
- https://github.com/openai/codex/blob/main/codex-rs/responses-api-proxy/README.md（官方 repo，wire_api='responses'）
- https://developers.openai.com/codex/config-advanced（官方 Codex 高级配置文档）
- https://omniroute.up.railway.app/docs/guides/CODEX-CLI-CONFIGURATION（2026-06，wire_api 变化说明，v0.138 起 "chat" 会崩溃）

---

## 第5节 Codex 的 gpt-5.x 模型名

**结论**: `gpt-5.6` 和 `gpt-5.5` 未被查证为确定存在的 OpenAI 模型名。搜索结果中出现的模型名包括 `gpt-5.2-codex`、`gpt-5.2`、`gpt-5.3-codex`、`gpt-5.1-codex-max`，这些来自第三方 gateway 配置示例，**非 OpenAI 官方 model ID 一手来源**。

**已查证（来自 2025 年 OpenAI developer blog）**:
- 2025 年推理模型演进为 GPT-5.x 系列，`GPT-5.2-Codex` 被描述为代码生成推荐模型
- OpenAI Responses API 发布于 2025 年 3 月，是 Codex 的原生协议

**置信度**: 低。gpt-5.x 模型 ID 会随时变化，**必须以 OpenAI 官方 API 或官方文档为准**。直接在 OpenAI playground 或 `openai.com/docs/models` 查当前可用模型列表。

**LiteLLM 里配置 openai provider**：

```yaml
- model_name: "gpt-5.2-codex"    # 对外暴露的别名
  litellm_params:
    model: "openai/gpt-5.2-codex" # openai/ 前缀指定 provider
    api_key: "os.environ/OPENAI_API_KEY"
```

注：OpenAI 模型必须走 OpenAI API，不能经 Bedrock，api_key 必须是真实 OpenAI key。

**来源**:
- https://developers.openai.com/blog/openai-for-developers-2025（2025 年 OpenAI 平台更新综述）
- https://github.com/feiskyer/claude-code-settings（第三方配置示例，仅供参考，非一手来源）

---

## 第6节 LiteLLM 暴露的端点

**结论**: LiteLLM proxy 默认暴露以下端点，无需额外配置开关：

| 端点 | 协议格式 | 用途 |
|------|----------|------|
| `/v1/chat/completions` | OpenAI Chat Completions | Hermes / OpenClaw / 通用 OpenAI 兼容客户端 |
| `/v1/messages` | Anthropic Messages | Claude Code（**推荐主入口**） |
| `/anthropic/v1/messages` | Anthropic passthrough | Claude Code 的 passthrough 路由（见注意事项） |
| `/v1/responses` | OpenAI Responses API | Codex CLI 默认协议 |
| `/bedrock/model/<name>/converse` | Bedrock Converse passthrough | 直接 Bedrock 格式调用 |
| `/bedrock/model/<name>/invoke` | Bedrock InvokeModel passthrough | 旧式 Bedrock 调用 |
| `/openai_passthrough/...` | OpenAI 直通 | 调 LiteLLM 未原生支持的 OpenAI 端点 |

**`/v1/messages` vs `/anthropic/v1/messages` 的区别**：
- `/v1/messages`（**推荐**）：LiteLLM 统一端点，支持 load balancing、fallback、cost tracking，会把 model 名路由到 model_list 里定义的 Bedrock 模型
- `/anthropic/v1/messages`：passthrough 端点，直接转发到 Anthropic API（需要真实 ANTHROPIC_API_KEY），不走 model_list，不做 provider 切换

**Bedrock passthrough 的开启**：在 model_list 里有 bedrock 模型就自动可用，访问 `/bedrock/model/<model_name>/converse` 即可，`model_name` 是 model_list 里定义的 `model_name` 字段值。

**来源**:
- https://docs.litellm.ai/docs/pass_through/anthropic_completion（Anthropic passthrough，查证日期 2026-07-27）
- https://docs.litellm.ai/docs/pass_through/bedrock（Bedrock passthrough）
- https://docs.litellm.ai/docs/response_api（/v1/responses 端点文档）
- https://docs.litellm.ai/docs/pass_through/openai_passthrough（OpenAI passthrough）
- https://docs.litellm.ai/docs/anthropic_unified/structured_output（/v1/messages 示例）

---

## 第7节 Claude Code 接入 LiteLLM

**结论**: 官方推荐用 `/v1/messages` 统一端点（不是 passthrough），通过两个环境变量配置。

**Anthropic 官方文档指引**（docs.anthropic.com/en/docs/claude-code/llm-gateway）：

```bash
# 最小配置：指向 LiteLLM 的 /v1/messages 统一端点
export ANTHROPIC_BASE_URL=https://<your-cf-domain>

# Auth token，作为 Authorization header 发送
export ANTHROPIC_AUTH_TOKEN=<litellm-master-key>
```

统一端点（`ANTHROPIC_BASE_URL` 直接指向根）的好处：load balancing、fallback、cost tracking 全部生效。

如果要直接走 passthrough 到 Anthropic 原生 API，改用：
```bash
export ANTHROPIC_BASE_URL=https://<your-cf-domain>/anthropic
```

**关于 ANTHROPIC_API_KEY vs ANTHROPIC_AUTH_TOKEN**:
- `ANTHROPIC_AUTH_TOKEN` 是 LiteLLM gateway 场景的正确变量（发给 gateway 的 key）
- `ANTHROPIC_API_KEY` 也可用，但含义是真实 Anthropic API key

**注意事项（官方文档原文）**:
- beta header 处理：gateway 必须完整转发 `anthropic-beta` 和 `anthropic-version` header，不得 allowlist 个别值（因为 Claude Code releases 会增加新 beta feature）
- 若在 Bedrock/Vertex passthrough 场景可能需要 `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`，但走 LiteLLM 统一端点不需要，LiteLLM 内部已做 per-provider 过滤
- 官方文档明确指出 LiteLLM 是第三方服务，Anthropic 不背书其安全性

**来源**:
- https://docs.anthropic.com/en/docs/claude-code/llm-gateway（Anthropic 官方文档，查证日期 2026-07-27）
- https://www.morphllm.com/claude-code-litellm（实战配置总结，2026-06-09）

---

## 第8节 Hermes agent 和 OpenClaw 接入

**结论**: 两者都走 OpenAI 兼容格式（`/v1/chat/completions`），无官方文档需要特殊配置。

**Hermes agent**（本项目的 trading/agent 框架）：基于 OpenAI SDK 或类 OpenAI 接口，配置：
```bash
OPENAI_BASE_URL=https://<your-cf-domain>/v1
OPENAI_API_KEY=<litellm-master-key>
```

**OpenClaw**：同样走 OpenAI 兼容接口，配置方式相同。项目文档见 `/docs/openclaw.md`。

若需要使用 Anthropic Messages 格式（更适合 Claude 模型的参数）：
```bash
ANTHROPIC_BASE_URL=https://<your-cf-domain>
ANTHROPIC_AUTH_TOKEN=<litellm-master-key>
```

**来源**: 未查到 Hermes/OpenClaw 专属接入文档，按 OpenAI 兼容格式接入为行业惯例。

---

## 附录：关于现有 Dockerfile patch 的迁移建议

现有 `docker/Dockerfile`（基于 `main-stable`）做了两件事：
1. RUN python3 修改 `anthropic_beta_headers_config.json`，把两个 header 设为 null
2. `ENV LITELLM_LOCAL_ANTHROPIC_BETA_HEADERS=True`

升级后的推荐 Dockerfile：

```dockerfile
FROM ghcr.io/berriai/litellm:latest   # 或固定版本如 :1.93.0

WORKDIR /app

# v1.81.13+ 内置 beta headers 过滤，不再需要 python3 patch
# 保留此环境变量：防止运行时从远端拉取新 config 覆盖本地（air-gapped 场景下重要）
ENV LITELLM_LOCAL_ANTHROPIC_BETA_HEADERS=True
```

**风险说明**: 新版本的 `anthropic_beta_headers_config.json` 是否已包含所有需要过滤的 header，需在升级后用实际的 Claude Code 请求测试确认。若出现新的 `invalid beta flag` 错误，对应处理方式：
1. 检查错误日志中的具体 header 名
2. 调用 `/reload/anthropic_beta_headers` API 热更新（无需重启）
3. 或在 Dockerfile 中重新加回针对性的 patch

**相关问题**: `context_management` 参数（不同于 beta header）在 v1.81.x 引入但 Bedrock 不支持时会报 `UnsupportedParamsError`，`drop_params: true`（litellm_settings 里已有）会自动处理这个问题。

---

*查证日期: 2026-07-27。所有 model ID 标注"需 AWS API 实测"的字段，运行 `aws bedrock list-inference-profiles` 获取精确值。*
