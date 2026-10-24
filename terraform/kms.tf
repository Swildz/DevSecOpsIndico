# ==============================================================================
# AWS KMS Customer Managed Keys (CMK) with Automatic Key Rotation
# ==============================================================================

resource "aws_kms_key" "app_cmk" {
  description             = "Dedicated CMK for application secrets, logs, and container image encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Account Root Administrator Access for Key Administration
      {
        Sid    = "EnableRootKeyAdministration"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      # Allow CloudWatch Logs to Encrypt Log Groups
      {
        Sid    = "AllowCloudWatchLogsEncryption"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      },
      # Allow ECS Task Execution Role to Decrypt Secrets
      {
        Sid    = "AllowECSTaskExecutionRoleDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.ecs_execution_role.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-cmk"
  }
}

resource "aws_kms_alias" "app_cmk_alias" {
  name          = "alias/${var.project_name}-${var.environment}-key"
  target_key_id = aws_kms_key.app_cmk.key_id
}
