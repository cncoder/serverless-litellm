#!/usr/bin/env bash
# ECS Fargate 最小栈一键部署
# 用法: ./deploy.sh [apply|destroy]
# 前置: AWS 凭据已配置、docker 在跑、terraform >=1.5
set -euo pipefail

cd "$(dirname "$0")"
REGION="${AWS_REGION:-us-east-1}"
ACTION="${1:-apply}"

# 绕系统代理直连 AWS
export NO_PROXY="*" https_proxy="" http_proxy=""

if [[ "$ACTION" == "destroy" ]]; then
  echo ">>> 销毁全部资源"
  terraform destroy -auto-approve
  echo ">>> 完成。请手动核查残留（见 README 销毁章节）"
  exit 0
fi

echo ">>> [1/5] terraform init"
terraform init -upgrade

echo ">>> [2/5] 先建 ECR（其余资源依赖镜像）"
terraform apply -target=aws_ecr_repository.litellm -auto-approve
ECR_URL=$(terraform output -raw ecr_repository_url)
echo "    ECR: $ECR_URL"

echo ">>> [3/5] build + push litellm 镜像"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ECR_URL%/*}"
docker build --platform linux/amd64 -f ../docker/Dockerfile -t "$ECR_URL:latest" ..
docker push "$ECR_URL:latest"

echo ">>> [4/5] apply 全部资源"
terraform apply -auto-approve

echo ">>> [5/5] 部署完成"
echo "网关地址: $(terraform output -raw cloudfront_url)"
echo "取 master key: $(terraform output -raw get_master_key_cmd)"
echo ""
echo "注意: CloudFront 分发生效需 ~5-10 分钟；ECS task 拉起需 ~2-3 分钟"
