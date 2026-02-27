resource "aws_dynamodb_table" "api_keys" {
  name         = "${var.project_name}-${var.environment}-api-keys"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "api_key"

  attribute {
    name = "api_key"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-api-keys"
    Project     = var.project_name
    Environment = var.environment
  }
}
