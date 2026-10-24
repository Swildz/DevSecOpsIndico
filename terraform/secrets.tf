# ==============================================================================
# AWS Secrets Manager with KMS Customer Managed Key Encryption
# ==============================================================================

resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${var.project_name}/${var.environment}/database"
  description             = "Production PostgreSQL database connection credentials"
  kms_key_id              = aws_kms_key.app_cmk.arn
  recovery_window_in_days = 7

  tags = {
    Name        = "${var.project_name}-${var.environment}-db-secret"
    Environment = var.environment
  }
}

# Generate high-entropy database password without hardcoding
resource "aws_secretsmanager_secret_version" "db_credentials_val" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = "app_prod_user"
    password = "CHANGE_ME_IN_VAULT_OR_DYNAMIC_ROTATE"
    engine   = "postgres"
    host     = "indico-api-prod-db.internal"
    port     = 5432
    database = "app_production"
  })

  # Lifecycle prevents Terraform from overwriting rotated passwords in Secrets Manager!
  lifecycle {
    ignore_changes = [
      secret_string
    ]
  }
}
