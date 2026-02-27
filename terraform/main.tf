locals {
  cluster_name = "${var.project_name}-eks-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
  }
  vpc_id             = var.create_vpc ? module.vpc[0].vpc_id : var.existing_vpc_id
  public_subnet_ids  = var.create_vpc ? module.vpc[0].public_subnet_ids : var.existing_public_subnet_ids
  private_subnet_ids = var.create_vpc ? module.vpc[0].private_subnet_ids : var.existing_private_subnet_ids
}

# VPC Module
module "vpc" {
  count  = var.create_vpc ? 1 : 0
  source = "./modules/vpc"

  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}

# IAM Base Module - EKS cluster role + Fargate execution role
# No dependency on EKS cluster itself (no circular dependency)
module "iam" {
  source = "./modules/iam"

  project_name = var.project_name
  environment  = var.environment
  cluster_name = local.cluster_name
}

# EKS Module
module "eks" {
  source = "./modules/eks"

  project_name                  = var.project_name
  environment                   = var.environment
  cluster_name                  = local.cluster_name
  eks_version                   = var.eks_version
  vpc_id                        = local.vpc_id
  private_subnet_ids            = local.private_subnet_ids
  cluster_role_arn              = module.iam.eks_cluster_role_arn
  fargate_pod_execution_role_arn = module.iam.fargate_pod_execution_role_arn
}

# OIDC Provider for IRSA (IAM Roles for Service Accounts)
# Must be created after EKS cluster, before IAM module
data "tls_certificate" "eks" {
  url        = module.eks.oidc_issuer_url
  depends_on = [module.eks]
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = module.eks.oidc_issuer_url

  tags = local.common_tags

  depends_on = [module.eks]
}

# IAM IRSA Module - LiteLLM pod role + ALB controller role
# Requires OIDC provider (created after EKS cluster) - no circular dependency
module "iam_irsa" {
  source = "./modules/iam-irsa"

  project_name                   = var.project_name
  environment                    = var.environment
  oidc_provider_arn              = aws_iam_openid_connect_provider.eks.arn
  oidc_provider_url              = replace(module.eks.oidc_issuer_url, "https://", "")
  litellm_namespace              = var.litellm_namespace
  litellm_service_account        = var.litellm_service_account
  dynamodb_table_arn             = module.dynamodb.table_arn

  depends_on = [aws_iam_openid_connect_provider.eks]
}

# ECR Module
module "ecr" {
  source       = "./modules/ecr"
  project_name = var.project_name
  environment  = var.environment
}

# DynamoDB Module
module "dynamodb" {
  source       = "./modules/dynamodb"
  project_name = var.project_name
  environment  = var.environment
}

# RDS PostgreSQL Module（LiteLLM Admin UI + 使用量统计）
module "rds" {
  source = "./modules/rds"

  project_name               = var.project_name
  environment                = var.environment
  vpc_id                     = local.vpc_id
  private_subnet_ids         = local.private_subnet_ids
  eks_node_security_group_id = module.eks.cluster_security_group_id

  depends_on = [module.eks]
}

# ALB Controller Module
# Uses IRSA (serviceAccount.annotations injected via Helm values) - Fargate compatible
module "alb_controller" {
  source = "./modules/alb-controller"

  project_name            = var.project_name
  environment             = var.environment
  cluster_name            = local.cluster_name
  cluster_endpoint        = module.eks.cluster_endpoint
  cluster_ca_certificate  = module.eks.cluster_ca_certificate
  alb_controller_role_arn = module.iam_irsa.alb_controller_role_arn
  vpc_id                  = local.vpc_id
  aws_region              = var.aws_region

  providers = {
    helm = helm
  }

  depends_on = [module.eks, module.iam_irsa]
}

# WAF Module
module "waf" {
  count  = var.enable_waf ? 1 : 0
  source = "./modules/waf"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  litellm_host = var.litellm_host
  bot_host     = var.bot_host

  depends_on = [module.post_deploy]
}

# Generate LiteLLM Master Key
resource "random_password" "litellm_master_key" {
  length  = 32
  special = false
}

# Store Master Key in Secrets Manager (persistent across state loss)
resource "aws_secretsmanager_secret" "litellm_master_key" {
  name                    = "${var.project_name}-master-key-${var.environment}"
  description             = "LiteLLM Master Key - format: sk-<random>"
  recovery_window_in_days = 0 # allow immediate deletion on terraform destroy

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "litellm_master_key" {
  secret_id     = aws_secretsmanager_secret.litellm_master_key.id
  secret_string = "sk-${random_password.litellm_master_key.result}"

  lifecycle {
    ignore_changes = [secret_string] # once written, manual rotation won't be overwritten
  }
}

# Post-deployment configuration
module "post_deploy" {
  source = "./modules/post-deploy"

  cluster_name            = local.cluster_name
  aws_region              = var.aws_region
  litellm_master_key      = aws_secretsmanager_secret_version.litellm_master_key.secret_string
  ecr_repository_url      = module.ecr.repository_url
  dynamodb_table_name     = module.dynamodb.table_name
  litellm_pod_role_arn    = module.iam_irsa.litellm_pod_role_arn
  database_url            = module.rds.database_url
  acm_certificate_arn     = var.acm_certificate_arn
  enable_cognito          = var.enable_cognito
  cognito_user_pool_arn       = var.cognito_user_pool_arn
  cognito_user_pool_client_id = var.cognito_user_pool_client_id
  cognito_user_pool_domain    = var.cognito_user_pool_domain
  litellm_host            = var.litellm_host
  bot_host                = var.bot_host
  eks_cluster_endpoint    = module.eks.cluster_endpoint

  depends_on = [
    module.eks,
    module.iam_irsa,
    module.dynamodb,
    module.ecr,
    module.alb_controller,
    module.rds,
  ]
}
