# LiteLLM Gateway 镜像 — serverless-litellm (fargate 分支)
#
# 零源码 patch：
#   - Claude 走 bedrock/ (IAM)，GPT 走 bedrock_mantle/ (Bedrock API key)，均为官方原生 provider
#   - anthropic beta headers 误报问题 v1.81.13+ 已官方修复，不再需要改 anthropic_beta_headers_config.json
#   - v1.93.0 官方发布说明标题即 "GPT-5.6, ..."，原生支持 GPT-5.6 系列
#
# 版本固定：main-stable tag 官方计划 2026-09-01 弃用，改用固定语义化版本 tag（ghcr 实测存在 v1.93.0 / 1.93.0）
FROM ghcr.io/berriai/litellm:v1.93.0

WORKDIR /app

# 用本地打包的 anthropic beta headers 配置，防止运行时远端拉取覆盖本地行为
ENV LITELLM_LOCAL_ANTHROPIC_BETA_HEADERS=True

# config.yaml 通过构建时 COPY（也可在 ECS task 用挂载/环境覆盖）
COPY litellm/config.yaml /app/config.yaml

EXPOSE 4000

# 仅推理端点，不启用 Admin UI
CMD ["--config", "/app/config.yaml", "--port", "4000", "--num_workers", "2"]
