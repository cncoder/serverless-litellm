#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_DIR/terraform"

echo "=== LiteLLM EKS Deployment ==="
echo ""

# Check prerequisites
for cmd in terraform aws kubectl docker; do
  if ! command -v $cmd &> /dev/null; then
    echo "Error: $cmd is not installed"
    exit 1
  fi
done

# Check AWS credentials
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$AWS_ACCOUNT" ]; then
  echo "Error: AWS credentials not configured"
  exit 1
fi
echo "AWS Account: $AWS_ACCOUNT"
echo "Region: us-west-2"
echo ""

cd "$TERRAFORM_DIR"

# Initialize Terraform
echo "--- Terraform Init ---"
terraform init

# Plan
echo ""
echo "--- Terraform Plan ---"
terraform plan -out=tfplan

# Confirm
echo ""
read -p "Apply changes? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

# Apply
echo ""
echo "--- Terraform Apply ---"
terraform apply tfplan
rm -f tfplan

# Show outputs
echo ""
echo "--- Deployment Complete ---"
echo ""
terraform output

echo ""
echo "=== Next Steps ==="
echo "1. Get ALB DNS: kubectl get ingress -n litellm litellm-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
echo "2. Create CNAME record: litellm.example.com -> <ALB_DNS>"
echo "3. Test: curl -H 'Authorization: Bearer <MASTER_KEY>' https://litellm.example.com/v1/models"
