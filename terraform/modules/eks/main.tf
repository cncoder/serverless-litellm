data "aws_caller_identity" "current" {}

locals {
  caller_arn = data.aws_caller_identity.current.arn
  # Convert STS assumed-role ARN to IAM role ARN for EKS access entries
  # STS format: arn:aws:sts::ACCOUNT:assumed-role/ROLE_NAME/SESSION_NAME
  # IAM format: arn:aws:iam::ACCOUNT:role/ROLE_NAME
  is_assumed_role = length(regexall("assumed-role", local.caller_arn)) > 0
  iam_role_arn = local.is_assumed_role ? format(
    "arn:aws:iam::%s:role/%s",
    data.aws_caller_identity.current.account_id,
    element(split("/", local.caller_arn), 1)
  ) : local.caller_arn
}

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = var.cluster_role_arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = {
    Name        = var.cluster_name
    Project     = var.project_name
    Environment = var.environment
  }
}

# Grant the Terraform executor (current IAM identity) cluster admin access
resource "aws_eks_access_entry" "terraform_executor" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = local.iam_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "terraform_executor_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = local.iam_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.terraform_executor]
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  depends_on = [aws_eks_cluster.main]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  configuration_values = jsonencode({
    computeType = "Fargate"
  })

  depends_on = [aws_eks_fargate_profile.default]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  depends_on = [aws_eks_cluster.main]
}


resource "aws_eks_fargate_profile" "default" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "${var.cluster_name}-fargate-default"
  pod_execution_role_arn = var.fargate_pod_execution_role_arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = "litellm"
  }

  selector {
    namespace = "kube-system"
  }

  tags = {
    Name        = "${var.cluster_name}-fargate-default"
    Project     = var.project_name
    Environment = var.environment
  }
}
