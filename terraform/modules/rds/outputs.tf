output "database_url" {
  description = "PostgreSQL DATABASE_URL for LiteLLM"
  value       = "postgresql://${aws_db_instance.main.username}:${random_password.db_password.result}@${aws_db_instance.main.endpoint}/${aws_db_instance.main.db_name}"
  sensitive   = true
}

output "db_endpoint" {
  description = "RDS endpoint (host:port)"
  value       = aws_db_instance.main.endpoint
}

output "db_identifier" {
  description = "RDS instance identifier"
  value       = aws_db_instance.main.identifier
}

output "db_password_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the DB password"
  value       = aws_secretsmanager_secret.db_password.arn
}

output "db_password_secret_id" {
  description = "ID (name) of the Secrets Manager secret containing the DB password"
  value       = aws_secretsmanager_secret.db_password.id
}

output "parameter_group_name" {
  description = "Name of the custom DB parameter group"
  value       = aws_db_parameter_group.main.name
}

output "database_url_base" {
  description = "PostgreSQL connection URL without password (for Init Container to construct)"
  value       = "postgresql://${aws_db_instance.main.username}:__DB_PASSWORD__@${aws_db_instance.main.endpoint}/${aws_db_instance.main.db_name}"
  sensitive   = false
}
