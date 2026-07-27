# LiteLLM Gateway on ECS Fargate（fargate 分支）

在 AWS 上部署一个**最小**的 LiteLLM 推理网关：**CloudFront → 内网 ALB → ECS Fargate → Bedrock**。
只暴露推理端点，单 master key 认证，**纯 IAM role SigV4，零静态凭据，不用任何 Bedrock API key**。

同一个网关同时支持 Claude Code、Codex、OpenClaw、Hermes 及任意 OpenAI 兼容客户端，覆盖 Claude 与 GPT 两大模型系、多模态、任意 Bedrock 模型。

## 支持的模型（已实测）

| 短名 | 后端 | 端点 |
|------|------|------|
| `opus-4-8` `fable-5` `opus-4-6` `sonnet-4-6` | Bedrock Converse (IAM) | chat / messages |
| `gpt-5.6-sol` `gpt-5.6-terra` `gpt-5.6-luna` `gpt-5.5` | Bedrock Mantle (IAM SigV4) | responses / chat |
| `bedrock/<任意模型>` | Bedrock 通配 | chat |

## 前置条件

- AWS 凭据（有 Bedrock、ECS、VPC、CloudFront、IAM 权限）
- Terraform ≥ 1.5、Docker、AWS CLI v2
- 账号已开通对应 Bedrock 模型（Claude 系 + OpenAI GPT via Mantle）

## 一键部署

```bash
cd ecs
./deploy.sh apply
```

`deploy.sh` 依次：init → 建 ECR → build+push 镜像 → apply 全栈。约 10-15 分钟（CloudFront 分发生效最慢）。

> 镜像默认 x86。若在 arm64 机器上 build，改 `ecs.tf` 的 `runtime_platform.cpu_architecture = "ARM64"`；或（推荐）在一台 x86 EC2 上跑 build+push。

部署完拿到：

```bash
terraform output cloudfront_url          # 网关地址
terraform output -raw get_master_key_cmd # 复制执行得到 master key
```

## 接入各 Agent

配置模板在 [`../examples/`](../examples/)，详细说明见 [`../docs/agent-integration.md`](../docs/agent-integration.md)：

- **Claude Code** → `examples/claude-code-settings.json`（`ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`）
- **Codex** → `examples/codex-config.toml`（`wire_api=responses`）
- **OpenClaw / Hermes / 通用 SDK** → `examples/openclaw-hermes.md`（OpenAI 兼容）

## 验证

```bash
CF=$(terraform output -raw cloudfront_url)
MK=$(eval "$(terraform output -raw get_master_key_cmd)")
curl -s $CF/v1/models -H "Authorization: Bearer $MK" | head
curl -s $CF/v1/chat/completions -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
  -d '{"model":"opus-4-8","messages":[{"role":"user","content":"hi"}],"max_tokens":20}'
```

## 销毁（测试完务必执行）

```bash
./deploy.sh destroy
# 或
terraform destroy -auto-approve
```

销毁后核查残留：ECR 镜像、CloudWatch 日志组、Secrets（`recovery_window_in_days=0` 即时删）。

## 架构要点

- **只通过 CloudFront 暴露**：ALB 入站 SG 只放 CloudFront origin-facing prefix list，且 listener 校验 `X-CF-Secret` 头，直连 ALB 返回 403。
- **零静态凭据**：ECS task role 挂 `AmazonBedrockFullAccess` + `bedrock-mantle:*`，Claude 和 GPT 全走 SigV4。
- **零源码 patch**：Claude 用 `bedrock/converse/`，GPT 用 `bedrock_mantle/` + `model_info` 覆盖能力标志（官方支持的 JSON 覆盖），都是 LiteLLM 官方原生 provider。
- **最小**：单 Fargate task（4GB/2vCPU，单 worker），无 RDS、无 Cognito、无 Admin UI。

## 文件

```
ecs/
  network.tf secrity.tf iam.tf secrets.tf ecr.tf alb.tf ecs.tf cloudfront.tf bastion.tf
  variables.tf outputs.tf versions.tf  deploy.sh
litellm/config.yaml   # 模型路由（核心）
docker/Dockerfile     # litellm v1.93.0，零 patch
```
