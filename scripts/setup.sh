#!/usr/bin/env bash

# LiteLLM on EKS - Interactive Setup Script
# This is the most important script in the project - comprehensive and robust deployment

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Script configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly TERRAFORM_DIR="${PROJECT_ROOT}/terraform"
readonly DOCKER_DIR="${PROJECT_ROOT}/docker"

# Mode flags (may be overridden by CLI args below)
USE_EXISTING_CONFIG=false

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_step() {
    echo -e "\n${CYAN}${BOLD}===================================================${NC}"
    echo -e "${CYAN}${BOLD}$*${NC}"
    echo -e "${CYAN}${BOLD}===================================================${NC}\n"
}

# Display ASCII art logo
display_logo() {
    cat << 'EOF'
    __    _ __       __    __  __  ___   ____  ____
   / /   (_) /____  / /   / / /  |/  /  / __ \/ __ \
  / /   / / __/ _ \/ /   / / / /|_/ /  / / / / /_/ /
 / /___/ / /_/  __/ /___/ /___  / /  / /_/ / ____/
/_____/_/\__/\___/_____/_____/_/_/   \____/_/

         LiteLLM on AWS EKS - Production Deployment
                    Interactive Setup v1.0

EOF
}

# Check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Prerequisite checks
check_prerequisites() {
    log_step "Step 1: Checking Prerequisites"

    local missing_tools=()

    # Required tools
    local required_tools=(
        "terraform:Terraform"
        "aws:AWS CLI"
        "kubectl:kubectl"
        "docker:Docker"
        "jq:jq"
        "envsubst:envsubst (gettext)"
    )

    for tool_pair in "${required_tools[@]}"; do
        IFS=':' read -r cmd name <<< "$tool_pair"
        if command_exists "$cmd"; then
            local version
            case "$cmd" in
                terraform)
                    version=$(terraform version -json | jq -r '.terraform_version')
                    ;;
                aws)
                    version=$(aws --version | cut -d' ' -f1 | cut -d'/' -f2)
                    ;;
                kubectl)
                    version=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' || echo "unknown")
                    ;;
                docker)
                    version=$(docker --version | cut -d' ' -f3 | tr -d ',')
                    ;;
                jq)
                    version=$(jq --version | cut -d'-' -f2)
                    ;;
                envsubst)
                    version=$(envsubst --version 2>&1 | head -1 | awk '{print $4}' || echo "installed")
                    ;;
            esac
            log_success "${name} installed (version: ${version})"
        else
            log_error "${name} is not installed"
            missing_tools+=("$name")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install missing tools before continuing"
        log_info "Installation guides:"
        log_info "  - Terraform: https://developer.hashicorp.com/terraform/downloads"
        log_info "  - AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        log_info "  - kubectl: https://kubernetes.io/docs/tasks/tools/"
        log_info "  - Docker: https://docs.docker.com/get-docker/"
        log_info "  - jq: brew install jq (macOS) or apt-get install jq (Ubuntu)"
        log_info "  - envsubst: brew install gettext (macOS) or apt-get install gettext (Ubuntu)"
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured or invalid"
        log_info "Run 'aws configure' to set up your credentials"
        exit 1
    fi

    local aws_identity
    aws_identity=$(aws sts get-caller-identity)
    local account_id
    account_id=$(echo "$aws_identity" | jq -r '.Account')
    local user_arn
    user_arn=$(echo "$aws_identity" | jq -r '.Arn')

    log_success "AWS credentials configured"
    log_info "  Account ID: ${account_id}"
    log_info "  User/Role: ${user_arn}"

    echo
}

# Prompt for user input with default value
prompt_input() {
    local prompt="$1"
    local default="$2"
    local result

    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${BLUE}${prompt}${NC} [${default}]: ")" result
        result="${result:-$default}"
    else
        read -rp "$(echo -e "${BLUE}${prompt}${NC}: ")" result
    fi

    echo "$result"
}

# Prompt for yes/no with default
prompt_yes_no() {
    local prompt="$1"
    local default="${2:-N}"
    local result

    if [[ "$default" == "y" || "$default" == "Y" ]]; then
        read -rp "$(echo -e "${BLUE}${prompt}${NC} (Y/n): ")" result
        result="${result:-Y}"
    else
        read -rp "$(echo -e "${BLUE}${prompt}${NC} (y/N): ")" result
        result="${result:-N}"
    fi

    [[ "$result" =~ ^[Yy]$ ]]
}

# Select AWS region
select_aws_region() {
    log_step "Step 2: AWS Region Selection"

    echo "Please select AWS Region:"
    echo "  1) us-east-1      (N. Virginia)"
    echo "  2) us-west-2      (Oregon)"
    echo "  3) ap-northeast-1 (Tokyo)"
    echo "  4) ap-southeast-1 (Singapore)"
    echo "  5) eu-west-1      (Ireland)"
    echo "  6) eu-central-1   (Frankfurt)"
    echo "  7) Custom input"
    echo

    local choice
    choice=$(prompt_input "Enter choice [1-7]" "2")

    case "$choice" in
        1) AWS_REGION="us-east-1" ;;
        2) AWS_REGION="us-west-2" ;;
        3) AWS_REGION="ap-northeast-1" ;;
        4) AWS_REGION="ap-southeast-1" ;;
        5) AWS_REGION="eu-west-1" ;;
        6) AWS_REGION="eu-central-1" ;;
        7)
            AWS_REGION=$(prompt_input "Enter AWS region" "us-west-2")
            ;;
        *)
            log_warning "Invalid choice, using default: us-west-2"
            AWS_REGION="us-west-2"
            ;;
    esac

    # Validate region
    log_info "Validating region: ${AWS_REGION}..."
    if ! aws ec2 describe-regions --region-names "$AWS_REGION" --query "Regions[0].RegionName" --output text &> /dev/null; then
        log_error "Invalid AWS region: ${AWS_REGION}"
        log_info "Run 'aws ec2 describe-regions' to see available regions"
        exit 1
    fi

    log_success "Region validated: ${AWS_REGION}"

    # Get and suggest availability zones
    log_info "Fetching availability zones for ${AWS_REGION}..."
    local azs
    azs=$(aws ec2 describe-availability-zones --region "$AWS_REGION" --query "AvailabilityZones[?State=='available'].ZoneName" --output json)
    local az_count
    az_count=$(echo "$azs" | jq -r '. | length')

    if [[ $az_count -ge 2 ]]; then
        local az1
        az1=$(echo "$azs" | jq -r '.[0]')
        local az2
        az2=$(echo "$azs" | jq -r '.[1]')
        AVAILABILITY_ZONES=("$az1" "$az2")
        log_success "Using availability zones: ${az1}, ${az2}"
    else
        log_error "Region ${AWS_REGION} does not have enough availability zones"
        exit 1
    fi

    echo
}

# VPC configuration
configure_vpc() {
    log_step "Step 3: VPC Configuration"

    echo "VPC Configuration:"
    echo "  1) Create new VPC (recommended)"
    echo "  2) Use existing VPC"
    echo

    local choice
    choice=$(prompt_input "Enter choice [1-2]" "1")

    if [[ "$choice" == "1" ]]; then
        # Create new VPC
        CREATE_VPC="true"
        VPC_CIDR=$(prompt_input "VPC CIDR block" "10.0.0.0/16")

        # Validate CIDR format
        if [[ ! "$VPC_CIDR" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            log_error "Invalid CIDR format. Using default: 10.0.0.0/16"
            VPC_CIDR="10.0.0.0/16"
        fi

        log_success "Will create new VPC with CIDR: ${VPC_CIDR}"
        log_info "Subnets will be automatically created across 2 availability zones"

        EXISTING_VPC_ID=""
        EXISTING_PUBLIC_SUBNETS=()
        EXISTING_PRIVATE_SUBNETS=()
    else
        # Use existing VPC
        CREATE_VPC="false"
        VPC_CIDR=""

        log_info "Fetching VPCs in region ${AWS_REGION}..."
        local vpcs
        vpcs=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
            --query "Vpcs[*].[VpcId,Tags[?Key=='Name']|[0].Value,CidrBlock]" \
            --output json)

        if [[ $(echo "$vpcs" | jq '. | length') -eq 0 ]]; then
            log_error "No VPCs found in region ${AWS_REGION}"
            log_info "Creating a new VPC instead..."
            CREATE_VPC="true"
            VPC_CIDR="10.0.0.0/16"
            EXISTING_VPC_ID=""
            EXISTING_PUBLIC_SUBNETS=()
            EXISTING_PRIVATE_SUBNETS=()
            echo
            return
        fi

        echo
        echo "Available VPCs:"
        echo "$vpcs" | jq -r 'to_entries[] | "\(.key + 1)) \(.value[0]) - \(.value[1] // "no-name") - \(.value[2])"'
        echo

        local vpc_choice
        vpc_choice=$(prompt_input "Enter VPC number" "1")
        EXISTING_VPC_ID=$(echo "$vpcs" | jq -r ".[$((vpc_choice-1))][0]")

        if [[ -z "$EXISTING_VPC_ID" || "$EXISTING_VPC_ID" == "null" ]]; then
            log_error "Invalid VPC selection"
            exit 1
        fi

        log_success "Selected VPC: ${EXISTING_VPC_ID}"

        # Fetch subnets
        log_info "Fetching subnets in VPC ${EXISTING_VPC_ID}..."
        local subnets
        subnets=$(aws ec2 describe-subnets --region "$AWS_REGION" \
            --filters "Name=vpc-id,Values=${EXISTING_VPC_ID}" \
            --query "Subnets[*].[SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch,Tags[?Key=='Name']|[0].Value]" \
            --output json)

        echo
        echo "Available Subnets:"
        printf "%-20s %-18s %-18s %-8s %s\n" "SubnetId" "AZ" "CIDR" "Public" "Name"
        echo "--------------------------------------------------------------------------------"
        echo "$subnets" | jq -r '.[] | @tsv' | while IFS=$'\t' read -r subnet_id az cidr public name; do
            printf "%-20s %-18s %-18s %-8s %s\n" "$subnet_id" "$az" "$cidr" "$public" "${name:-no-name}"
        done
        echo

        # Select public subnets
        log_info "Select 2 PUBLIC subnets (enter subnet IDs separated by comma)"
        log_info "Example: subnet-abc123,subnet-def456"
        local public_input
        public_input=$(prompt_input "Public subnet IDs" "")
        IFS=',' read -ra EXISTING_PUBLIC_SUBNETS <<< "${public_input// /}"

        if [[ ${#EXISTING_PUBLIC_SUBNETS[@]} -lt 2 ]]; then
            log_error "Must select at least 2 public subnets"
            exit 1
        fi

        # Select private subnets
        log_info "Select 2 PRIVATE subnets (enter subnet IDs separated by comma)"
        log_info "Example: subnet-ghi789,subnet-jkl012"
        local private_input
        private_input=$(prompt_input "Private subnet IDs" "")
        IFS=',' read -ra EXISTING_PRIVATE_SUBNETS <<< "${private_input// /}"

        if [[ ${#EXISTING_PRIVATE_SUBNETS[@]} -lt 2 ]]; then
            log_error "Must select at least 2 private subnets"
            exit 1
        fi

        log_success "Public subnets: ${EXISTING_PUBLIC_SUBNETS[*]}"
        log_success "Private subnets: ${EXISTING_PRIVATE_SUBNETS[*]}"
    fi

    echo
}

# Optional components configuration
configure_optional_components() {
    log_step "Step 4: Optional Components"

    # WAF configuration
    if prompt_yes_no "Enable WAF (Web Application Firewall) protection?" "N"; then
        ENABLE_WAF="true"
        log_success "WAF protection will be enabled"
    else
        ENABLE_WAF="false"
        log_info "WAF protection disabled"
    fi

    echo

    # Cognito configuration
    if prompt_yes_no "Enable Cognito UI authentication?" "N"; then
        ENABLE_COGNITO="true"
        echo
        COGNITO_USER_POOL_ARN=$(prompt_input "Cognito User Pool ARN" "")
        COGNITO_CLIENT_ID=$(prompt_input "Cognito User Pool Client ID" "")
        COGNITO_DOMAIN=$(prompt_input "Cognito User Pool Domain" "")

        if [[ -z "$COGNITO_USER_POOL_ARN" || -z "$COGNITO_CLIENT_ID" || -z "$COGNITO_DOMAIN" ]]; then
            log_error "All Cognito fields are required when enabling authentication"
            exit 1
        fi

        log_success "Cognito authentication configured"
    else
        ENABLE_COGNITO="false"
        COGNITO_USER_POOL_ARN=""
        COGNITO_CLIENT_ID=""
        COGNITO_DOMAIN=""
        log_info "Cognito authentication disabled"
    fi

    echo
}

# Domain and certificate configuration
configure_domains() {
    log_step "Step 5: Domain and Certificate Configuration"

    LITELLM_HOST=$(prompt_input "LiteLLM API domain (e.g., litellm.example.com)" "litellm.example.com")
    BOT_HOST=$(prompt_input "Bot/Webhook domain (leave empty to skip)" "")

    if [[ -z "$BOT_HOST" ]]; then
        BOT_HOST="bot.example.com"  # Default placeholder
        log_info "Bot domain not configured, using placeholder"
    fi

    echo
    echo -e "${CYAN}ACM Certificate Configuration:${NC}"
    echo "  If your domain DNS is on Cloudflare or another provider, you may not have"
    echo "  a certificate yet. You can deploy in 2 phases:"
    echo
    echo "  Phase 1 (now):   Leave empty → deploy HTTP only → get ALB DNS → create CNAME"
    echo "  Phase 2 (later): Fill in ARN → re-run 'terraform apply' → auto-switch to HTTPS"
    echo
    ACM_CERTIFICATE_ARN=$(prompt_input "ACM Certificate ARN (leave empty for HTTP-only Phase 1)" "")

    if [[ -z "$ACM_CERTIFICATE_ARN" ]]; then
        log_warning "No ACM certificate — will deploy HTTP only (Phase 1)."
        echo
        echo -e "${YELLOW}${BOLD}Phase 1 deployment plan:${NC}"
        echo "  1. Terraform deploys infrastructure (HTTP on port 80)"
        echo "  2. After deploy: get the ALB DNS hostname"
        echo "  3. In Cloudflare (or your DNS): create CNAME records:"
        echo "       ${LITELLM_HOST}  →  <ALB DNS>"
        echo "       ${BOT_HOST}      →  <ALB DNS>"
        echo "  4. In AWS Certificate Manager (region: ${AWS_REGION}):"
        echo "       a. Request public certificate for your domain(s)"
        echo "       b. Choose DNS validation"
        echo "       c. AWS gives you a CNAME record — add it in Cloudflare"
        echo "       d. Wait for status: Issued (usually 5-30 minutes)"
        echo "  5. Copy the certificate ARN"
        echo "  6. Edit terraform/terraform.tfvars → set acm_certificate_arn = \"arn:...\""
        echo "  7. Run: cd terraform && terraform apply"
        echo "     → Automatically switches to HTTPS ingress"
        echo
        DEPLOYMENT_PHASE="http"
    else
        # Validate certificate ARN format
        if [[ ! "$ACM_CERTIFICATE_ARN" =~ ^arn:aws:acm: ]]; then
            log_error "Invalid ACM certificate ARN format"
            exit 1
        fi
        log_success "ACM certificate configured — will deploy with HTTPS"
        DEPLOYMENT_PHASE="https"
    fi

    echo
}

# Display configuration summary
display_summary() {
    log_step "Step 6: Configuration Summary"

    cat << EOF
${BOLD}Configuration Summary:${NC}
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

${BOLD}Project Settings:${NC}
  Project Name:          litellm
  Environment:           production
  AWS Region:            ${AWS_REGION}
  Availability Zones:    ${AVAILABILITY_ZONES[0]}, ${AVAILABILITY_ZONES[1]}

${BOLD}Network Configuration:${NC}
EOF

    if [[ "$CREATE_VPC" == "true" ]]; then
        cat << EOF
  VPC Mode:              Create new VPC
  VPC CIDR:              ${VPC_CIDR}
  Subnets:               Auto-created across 2 AZs
EOF
    else
        cat << EOF
  VPC Mode:              Use existing VPC
  VPC ID:                ${EXISTING_VPC_ID}
  Public Subnets:        ${EXISTING_PUBLIC_SUBNETS[*]}
  Private Subnets:       ${EXISTING_PRIVATE_SUBNETS[*]}
EOF
    fi

    cat << EOF

${BOLD}Security & Features:${NC}
  WAF Protection:        ${ENABLE_WAF}
  Cognito Auth:          ${ENABLE_COGNITO}
EOF

    if [[ "$ENABLE_COGNITO" == "true" ]]; then
        echo "  Cognito User Pool:     ${COGNITO_USER_POOL_ARN}"
    fi

    cat << EOF

${BOLD}Domain Configuration:${NC}
  LiteLLM API:           ${LITELLM_HOST}
  Bot/Webhook:           ${BOT_HOST}
  ACM Certificate:       ${ACM_CERTIFICATE_ARN:-"(Phase 1: HTTP only)"}
  Deployment Phase:      ${DEPLOYMENT_PHASE:-https}

${BOLD}Infrastructure:${NC}
  EKS Version:           1.31
  Compute:               AWS Fargate (serverless)
  Storage:               DynamoDB (API keys)

${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
EOF

    echo
    if ! prompt_yes_no "Continue with this configuration?" "Y"; then
        log_info "Deployment cancelled by user"
        exit 0
    fi

    echo
}

# Generate terraform.tfvars
generate_tfvars() {
    log_step "Step 7: Generating Terraform Configuration"

    local tfvars_file="${TERRAFORM_DIR}/terraform.tfvars"

    log_info "Generating ${tfvars_file}..."

    cat > "$tfvars_file" << EOF
# LiteLLM on EKS - Terraform Configuration
# Generated by setup.sh on $(date)

# Project configuration
project_name = "litellm"
environment  = "production"
aws_region   = "${AWS_REGION}"

# Network configuration
create_vpc         = ${CREATE_VPC}
EOF

    if [[ "$CREATE_VPC" == "true" ]]; then
        cat >> "$tfvars_file" << EOF
vpc_cidr           = "${VPC_CIDR}"
availability_zones = ["${AVAILABILITY_ZONES[0]}", "${AVAILABILITY_ZONES[1]}"]
EOF
    else
        # Convert arrays to terraform list format
        local public_subnets_str
        public_subnets_str=$(printf '"%s",' "${EXISTING_PUBLIC_SUBNETS[@]}")
        public_subnets_str="[${public_subnets_str%,}]"

        local private_subnets_str
        private_subnets_str=$(printf '"%s",' "${EXISTING_PRIVATE_SUBNETS[@]}")
        private_subnets_str="[${private_subnets_str%,}]"

        cat >> "$tfvars_file" << EOF
existing_vpc_id            = "${EXISTING_VPC_ID}"
existing_public_subnet_ids = ${public_subnets_str}
existing_private_subnet_ids = ${private_subnets_str}
availability_zones         = ["${AVAILABILITY_ZONES[0]}", "${AVAILABILITY_ZONES[1]}"]
EOF
    fi

    cat >> "$tfvars_file" << EOF

# EKS configuration
eks_version = "1.31"

# Domain and SSL
litellm_host        = "${LITELLM_HOST}"
bot_host            = "${BOT_HOST}"
acm_certificate_arn = "${ACM_CERTIFICATE_ARN}"

# Cognito authentication (optional)
enable_cognito              = ${ENABLE_COGNITO}
cognito_user_pool_arn       = "${COGNITO_USER_POOL_ARN}"
cognito_user_pool_client_id = "${COGNITO_CLIENT_ID}"
cognito_user_pool_domain    = "${COGNITO_DOMAIN}"

# Kubernetes configuration
litellm_namespace       = "litellm"
litellm_service_account = "litellm-sa"

# Security
enable_waf = ${ENABLE_WAF}
EOF

    log_success "Configuration file generated: ${tfvars_file}"
    echo
}

# Deploy infrastructure with Terraform
deploy_terraform() {
    log_step "Step 8: Deploying Infrastructure with Terraform"

    cd "$TERRAFORM_DIR" || exit 1

    # Initialize Terraform
    log_info "Initializing Terraform..."
    if terraform init; then
        log_success "Terraform initialized"
    else
        log_error "Terraform initialization failed"
        exit 1
    fi

    echo

    # Create plan
    log_info "Creating Terraform plan..."
    if terraform plan -out=tfplan; then
        log_success "Terraform plan created"
    else
        log_error "Terraform plan failed"
        log_info "Check the error messages above and fix any issues"
        exit 1
    fi

    echo
    log_info "Terraform plan summary:"
    terraform show -json tfplan | jq -r '
        .resource_changes[] |
        select(.change.actions != ["no-op"]) |
        "\(.change.actions[0]): \(.type).\(.name)"
    ' | head -20

    echo
    if ! prompt_yes_no "Apply this Terraform plan?" "Y"; then
        log_info "Deployment cancelled by user"
        exit 0
    fi

    echo
    log_info "Applying Terraform plan... (this may take 15-20 minutes)"
    if terraform apply tfplan; then
        log_success "Infrastructure deployed successfully!"
    else
        log_error "Terraform apply failed"
        log_info "Check the error messages above. You can retry with:"
        log_info "  cd ${TERRAFORM_DIR} && terraform apply"
        exit 1
    fi

    echo

    # Save outputs
    log_info "Saving Terraform outputs..."
    terraform output -json > "${PROJECT_ROOT}/.terraform-outputs.json"

    cd "$PROJECT_ROOT" || exit 1
    echo
}

# Build and push Docker image
build_and_push_image() {
    log_step "Step 9: Building and Pushing Docker Image"

    # Get ECR repository URL from Terraform outputs
    local ecr_url
    ecr_url=$(cd "$TERRAFORM_DIR" && terraform output -raw ecr_repository_url 2>/dev/null || echo "")

    if [[ -z "$ecr_url" ]]; then
        log_error "Failed to get ECR repository URL from Terraform outputs"
        exit 1
    fi

    log_success "ECR Repository: ${ecr_url}"

    # Login to ECR
    log_info "Logging in to Amazon ECR..."
    if aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ecr_url"; then
        log_success "Logged in to ECR"
    else
        log_error "Failed to login to ECR"
        exit 1
    fi

    echo

    # Build Docker image
    log_info "Building Docker image..."
    cd "$DOCKER_DIR" || exit 1

    if docker build -t litellm-custom:latest .; then
        log_success "Docker image built successfully"
    else
        log_error "Docker build failed"
        exit 1
    fi

    echo

    # Tag and push image
    log_info "Tagging image..."
    docker tag litellm-custom:latest "${ecr_url}:latest"

    log_info "Pushing image to ECR... (this may take a few minutes)"
    if docker push "${ecr_url}:latest"; then
        log_success "Image pushed to ECR successfully"
    else
        log_error "Failed to push image to ECR"
        exit 1
    fi

    cd "$PROJECT_ROOT" || exit 1
    echo
}

# Configure kubectl
configure_kubectl() {
    log_step "Step 10: Configuring kubectl"

    local cluster_name
    cluster_name=$(cd "$TERRAFORM_DIR" && terraform output -raw eks_cluster_name 2>/dev/null || echo "")

    if [[ -z "$cluster_name" ]]; then
        log_error "Failed to get EKS cluster name from Terraform outputs"
        exit 1
    fi

    log_info "Updating kubeconfig for cluster: ${cluster_name}..."
    if aws eks update-kubeconfig --name "$cluster_name" --region "$AWS_REGION"; then
        log_success "kubectl configured successfully"
    else
        log_error "Failed to configure kubectl"
        exit 1
    fi

    echo
    log_info "Verifying cluster access..."
    if kubectl cluster-info; then
        log_success "Successfully connected to EKS cluster"
    else
        log_warning "Could not verify cluster access. The cluster may still be initializing."
    fi

    echo
}

# Create initial admin key
create_admin_key() {
    log_step "Step 11: Creating Initial Admin Key"

    log_info "Generating admin API key..."
    ADMIN_KEY="sk-admin-$(openssl rand -hex 16)"

    log_success "Admin key generated (will be displayed at the end)"
    echo
}

# Display final deployment information
display_deployment_info() {
    log_step "Deployment Complete!"

    # Extract Terraform outputs
    local cluster_name eks_endpoint dynamodb_table ecr_url master_key alb_hostname vpc_id

    cd "$TERRAFORM_DIR" || exit 1

    cluster_name=$(terraform output -raw eks_cluster_name 2>/dev/null || echo "N/A")
    eks_endpoint=$(terraform output -raw eks_cluster_endpoint 2>/dev/null || echo "N/A")
    dynamodb_table=$(terraform output -raw dynamodb_table_name 2>/dev/null || echo "N/A")
    ecr_url=$(terraform output -raw ecr_repository_url 2>/dev/null || echo "N/A")
    master_key=$(terraform output -raw litellm_master_key 2>/dev/null || echo "N/A")
    vpc_id=$(terraform output -raw vpc_id 2>/dev/null || echo "N/A")

    # Get ALB hostname (may take a few minutes to provision)
    alb_hostname=$(kubectl get ingress -n litellm litellm-ingress-ui -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "(pending - may take 5-10 minutes)")

    cd "$PROJECT_ROOT" || exit 1

    cat << EOF

${GREEN}${BOLD}╔════════════════════════════════════════════════════════════╗
║                  DEPLOYMENT SUCCESSFUL!                    ║
╚════════════════════════════════════════════════════════════╝${NC}

${BOLD}Infrastructure Details:${NC}
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
  VPC ID:                ${vpc_id}
  EKS Cluster:           ${cluster_name}
  Cluster Endpoint:      ${eks_endpoint}
  ECR Repository:        ${ecr_url}
  DynamoDB Table:        ${dynamodb_table}

${BOLD}Access Credentials:${NC}
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
  ${YELLOW}Master Key:${NC}            ${master_key}
  ${YELLOW}Admin API Key:${NC}         ${ADMIN_KEY}

${RED}${BOLD}⚠️  IMPORTANT: Save these keys securely! They won't be shown again.${NC}

${BOLD}Application Endpoints:${NC}
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
EOF
    local proto="https"
    [[ "${DEPLOYMENT_PHASE:-https}" == "http" ]] && proto="http"
    cat << EOF
  LiteLLM API:           ${proto}://${LITELLM_HOST}
  Bot/Webhook:           ${proto}://${BOT_HOST}
  ALB Hostname:          ${alb_hostname}
  Deployment Mode:       ${DEPLOYMENT_PHASE:-https}

${BOLD}Next Steps:${NC}
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
EOF

    if [[ "${DEPLOYMENT_PHASE:-https}" == "http" ]]; then
        cat << EOF
${YELLOW}${BOLD}⚡ Phase 1 (HTTP) — Steps to complete:${NC}

  ${GREEN}1.${NC} Create DNS CNAME records in Cloudflare (or your DNS provider):
     ${LITELLM_HOST}  →  ${alb_hostname}
     ${BOT_HOST}      →  ${alb_hostname}

  ${GREEN}2.${NC} Request ACM certificate in AWS Certificate Manager (region: ${AWS_REGION}):
     a. Go to: https://console.aws.amazon.com/acm/home?region=${AWS_REGION}
     b. Click "Request certificate" → Public certificate
     c. Enter domain names: ${LITELLM_HOST} and ${BOT_HOST}
     d. Choose DNS validation
     e. AWS will give you CNAME validation records — add them in Cloudflare
     f. Wait for status: Issued (usually 5-30 minutes)
     g. Copy the certificate ARN

  ${GREEN}3.${NC} Switch to HTTPS (Phase 2):
     Edit ${TERRAFORM_DIR}/terraform.tfvars:
       acm_certificate_arn = "arn:aws:acm:${AWS_REGION}:..."
     Then run:
       cd ${TERRAFORM_DIR} && terraform apply

  ${GREEN}4.${NC} Verify HTTP is working now:
     curl http://${LITELLM_HOST}/health

  ${GREEN}5.${NC} Monitor pods:
     kubectl get pods -n litellm
     kubectl logs -n litellm -l app=litellm --tail=100

EOF
    else
        cat << EOF
  ${GREEN}1.${NC} Create DNS records:
     ${LITELLM_HOST}  CNAME  ${alb_hostname}
     ${BOT_HOST}      CNAME  ${alb_hostname}

  ${GREEN}2.${NC} Wait for DNS propagation (may take 5-10 minutes)

  ${GREEN}3.${NC} Test the deployment:
     curl https://${LITELLM_HOST}/health

  ${GREEN}4.${NC} Make your first API call:
     curl -X POST https://${LITELLM_HOST}/v1/chat/completions \\
       -H "Authorization: Bearer ${ADMIN_KEY}" \\
       -H "Content-Type: application/json" \\
       -d '{
         "model": "bedrock/us.anthropic.claude-sonnet-4-6",
         "messages": [{"role": "user", "content": "Hello!"}]
       }'

  ${GREEN}5.${NC} Create additional API keys:
     cd ${SCRIPT_DIR}
     ./manage-keys.sh create user@example.com

  ${GREEN}6.${NC} Monitor your deployment:
     kubectl get pods -n litellm
     kubectl logs -n litellm -l app=litellm --tail=100

EOF
    fi

    cat << EOF

${BOLD}Useful Commands:${NC}
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
  View all resources:      kubectl get all -n litellm
  Check logs:              kubectl logs -n litellm -l app=litellm -f
  Update kubeconfig:       aws eks update-kubeconfig --name ${cluster_name} --region ${AWS_REGION}
  Destroy infrastructure:  cd ${TERRAFORM_DIR} && terraform destroy

${BOLD}Documentation:${NC}
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
  README:                  ${PROJECT_ROOT}/README.md
  API Usage:               ${PROJECT_ROOT}/docs/API_USAGE.md
  Testing Guide:           ${PROJECT_ROOT}/TESTING_GUIDE.md
  Troubleshooting:         ${PROJECT_ROOT}/TROUBLESHOOTING.md

${GREEN}${BOLD}╔════════════════════════════════════════════════════════════╗
║           Thank you for using LiteLLM on EKS!             ║
╚════════════════════════════════════════════════════════════╝${NC}

EOF
}

# Load configuration from existing terraform.tfvars (non-interactive mode)
load_existing_config() {
    local tfvars_file="${TERRAFORM_DIR}/terraform.tfvars"

    if [[ ! -f "$tfvars_file" ]]; then
        log_error "terraform.tfvars not found: ${tfvars_file}"
        log_error "Please run setup.sh without --use-existing-config to configure first"
        exit 1
    fi

    log_info "Loading configuration from ${tfvars_file}..."

    # Helper: extract quoted string value after '=' from tfvars line (POSIX sed, macOS compatible)
    tfvar_str() { grep -E "^$1[[:space:]]*=" "$tfvars_file" | sed 's/^[^=]*=[[:space:]]*"\([^"]*\)".*/\1/'; }
    # Helper: extract unquoted boolean/number value after '=' from tfvars line
    tfvar_val() { grep -E "^$1[[:space:]]*=" "$tfvars_file" | sed 's/^[^=]*=[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d ' '; }

    AWS_REGION=$(tfvar_str aws_region)
    CREATE_VPC=$(tfvar_val create_vpc)
    EXISTING_VPC_ID=$(tfvar_str existing_vpc_id)
    LITELLM_HOST=$(tfvar_str litellm_host)
    BOT_HOST=$(tfvar_str bot_host)
    ACM_CERTIFICATE_ARN=$(tfvar_str acm_certificate_arn)
    ENABLE_WAF=$(tfvar_val enable_waf)
    ENABLE_COGNITO=$(tfvar_val enable_cognito)

    # Determine deployment phase
    if [[ -n "$ACM_CERTIFICATE_ARN" ]]; then
        DEPLOYMENT_PHASE="https"
    else
        DEPLOYMENT_PHASE="http"
    fi

    # Get AZs from AWS
    log_info "Fetching availability zones for ${AWS_REGION}..."
    local azs
    azs=$(aws ec2 describe-availability-zones --region "$AWS_REGION" --query "AvailabilityZones[?State=='available'].ZoneName" --output json)
    AVAILABILITY_ZONES=("$(echo "$azs" | jq -r '.[0]')" "$(echo "$azs" | jq -r '.[1]')")

    log_success "Loaded: region=${AWS_REGION}, host=${LITELLM_HOST}, phase=${DEPLOYMENT_PHASE}"
    echo
}

# Parse CLI arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --use-existing-config)
                USE_EXISTING_CONFIG=true
                shift
                ;;
            *)
                log_error "Unknown argument: $1"
                echo "Usage: $0 [--use-existing-config]"
                echo "  --use-existing-config  Skip interactive config, use existing terraform.tfvars"
                exit 1
                ;;
        esac
    done
}

# Main execution flow
main() {
    parse_args "$@"

    # Display welcome
    clear
    display_logo

    if [[ "$USE_EXISTING_CONFIG" == "true" ]]; then
        echo -e "${CYAN}Non-interactive mode: using existing terraform.tfvars${NC}"
        echo

        check_prerequisites

        log_info "Loading existing configuration..."
        load_existing_config

        # Show what we loaded
        log_step "Configuration loaded from terraform.tfvars"
        echo "  AWS Region:   ${AWS_REGION}"
        echo "  VPC Mode:     $([ "$CREATE_VPC" = "true" ] && echo "create new" || echo "use existing (${EXISTING_VPC_ID})")"
        echo "  LiteLLM Host: ${LITELLM_HOST}"
        echo "  ACM Cert:     ${ACM_CERTIFICATE_ARN:-(none, HTTP only)}"
        echo "  WAF:          ${ENABLE_WAF}"
        echo "  Cognito:      ${ENABLE_COGNITO}"
        echo

        deploy_terraform
        build_and_push_image
        configure_kubectl
        create_admin_key
        display_deployment_info
    else
        echo -e "${CYAN}This script will guide you through deploying LiteLLM on AWS EKS.${NC}"
        echo -e "${CYAN}The entire process will take approximately 20-25 minutes.${NC}"
        echo

        if ! prompt_yes_no "Ready to begin?" "Y"; then
            log_info "Setup cancelled by user"
            exit 0
        fi

        # Execute deployment steps
        check_prerequisites
        select_aws_region
        configure_vpc
        configure_optional_components
        configure_domains
        display_summary
        generate_tfvars
        deploy_terraform
        build_and_push_image
        configure_kubectl
        create_admin_key
        display_deployment_info
    fi

    log_success "Setup complete! Your LiteLLM deployment is ready."
}

# Run main function
main "$@"

