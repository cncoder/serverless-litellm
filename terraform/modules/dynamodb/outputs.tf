output "table_name" {
  description = "DynamoDB API keys table name"
  value       = aws_dynamodb_table.api_keys.name
}

output "table_arn" {
  description = "DynamoDB API keys table ARN"
  value       = aws_dynamodb_table.api_keys.arn
}
