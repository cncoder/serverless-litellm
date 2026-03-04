# RDS PostgreSQL - LiteLLM 数据库（用于 Admin UI + 使用量统计）
# 实例类型：db.t4g.micro (~$12/月，足够 LiteLLM 日志量)

# DB Subnet Group（使用 private 子网，不暴露公网）
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-rds-subnet-group-${var.environment}"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name        = "${var.project_name}-rds-subnet-group-${var.environment}"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Security Group：仅允许 EKS 节点（Fargate pods）访问 5432
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg-${var.environment}"
  description = "Security group for RDS PostgreSQL - LiteLLM"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS Fargate pods"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-rds-sg-${var.environment}"
    Project     = var.project_name
    Environment = var.environment
  }
}

# 随机密码（32位，无特殊字符避免 URL 编码问题）
resource "random_password" "db_password" {
  length  = 32
  special = false
}

# 存入 Secrets Manager
resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.project_name}-rds-password-${var.environment}"
  description             = "RDS PostgreSQL password for LiteLLM"
  recovery_window_in_days = 0

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db_password.result

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Custom Parameter Group（避免使用 AWS 默认参数组）
resource "aws_db_parameter_group" "main" {
  name        = "${var.project_name}-pg-${var.environment}"
  family      = "postgres16"
  description = "Custom parameter group for LiteLLM PostgreSQL"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  tags = {
    Name        = "${var.project_name}-pg-${var.environment}"
    Project     = var.project_name
    Environment = var.environment
  }
}

# RDS PostgreSQL t4g.micro（单 AZ，无多活，成本最优）
resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-postgres-${var.environment}"

  # Engine
  engine               = "postgres"
  engine_version       = "16.6"
  instance_class       = "db.t4g.micro"

  # Storage（gp3，20GB 起步足够）
  allocated_storage     = 20
  max_allocated_storage = 100  # autoscaling 上限
  storage_type          = "gp3"
  storage_encrypted     = true

  # Database
  db_name  = "litellm"
  username = "litellm"
  password = random_password.db_password.result

  # Network
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false  # 单 AZ，省钱

  # Backup（保留 7 天，防止误操作）
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  # 删除保护（生产环境默认开启）
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.project_name}-postgres-final-${var.environment}"

  # 自定义参数组
  parameter_group_name = aws_db_parameter_group.main.name

  # 性能优化
  performance_insights_enabled = false  # t4g.micro 不支持
  monitoring_interval          = 0      # 不启用 Enhanced Monitoring（省费）

  tags = {
    Name        = "${var.project_name}-postgres-${var.environment}"
    Project     = var.project_name
    Environment = var.environment
  }
}
