# ---------------------------------------------------------------------------
# ECS Fargate：集群 + task definition + service
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "litellm" {
  name              = "/ecs/${local.name}"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_ecs_cluster" "main" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "disabled" # 最小栈省成本
  }
  tags = local.tags
}

resource "aws_ecs_task_definition" "litellm" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # 镜像在 x86 堡垒机上 build，Fargate 用 X86_64 匹配
  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name      = "litellm"
    image     = "${aws_ecr_repository.litellm.repository_url}:${var.image_tag}"
    essential = true
    # 覆盖镜像 CMD：单 worker 降内存占用（配合本地 cost map 避免 OOM）
    command = ["--config", "/app/config.yaml", "--port", "4000", "--num_workers", "1"]
    portMappings = [{
      containerPort = 4000
      protocol      = "tcp"
    }]
    environment = [
      { name = "LITELLM_LOCAL_MODEL_COST_MAP", value = "True" },
      { name = "LITELLM_LOCAL_ANTHROPIC_BETA_HEADERS", value = "True" },
      { name = "AWS_REGION_NAME", value = var.bedrock_region },
      { name = "AWS_REGION", value = var.bedrock_region },
    ]
    # 仅注入 master key。GPT/Claude 全走 task role 的 IAM SigV4，无任何 bearer token
    secrets = [
      { name = "LITELLM_MASTER_KEY", valueFrom = aws_secretsmanager_secret.master_key.arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.litellm.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "litellm"
      }
    }
  }])

  tags = local.tags
}

resource "aws_ecs_service" "litellm" {
  name            = local.name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.litellm.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false # 私有子网走 NAT
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.litellm.arn
    container_name   = "litellm"
    container_port   = 4000
  }

  health_check_grace_period_seconds = 120
  # 依赖真正关联 target group 的 listener rule，避免 fresh apply 时
  # "target group 尚未关联 load balancer" 的竞态
  depends_on = [aws_lb_listener.http, aws_lb_listener_rule.cf_only]
  tags       = local.tags
}
