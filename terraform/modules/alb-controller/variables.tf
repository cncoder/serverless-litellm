variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "cluster_ca_certificate" {
  type = string
}

variable "alb_controller_role_arn" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "aws_region" {
  description = "AWS region for ALB controller"
  type        = string
}
