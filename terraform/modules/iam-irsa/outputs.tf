output "litellm_pod_role_arn" {
  description = "ARN of the LiteLLM pod IAM role (IRSA)"
  value       = aws_iam_role.litellm_pod.arn
}

output "alb_controller_role_arn" {
  description = "ARN of the ALB controller IAM role (IRSA)"
  value       = aws_iam_role.alb_controller.arn
}
