output "eks_cluster_role_arn" {
  description = "ARN of the EKS cluster IAM role"
  value       = aws_iam_role.eks_cluster.arn
}

output "fargate_pod_execution_role_arn" {
  description = "ARN of the Fargate pod execution IAM role"
  value       = aws_iam_role.fargate_pod_execution.arn
}
