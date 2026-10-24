# ==============================================================================
# AWS KMS Customer Managed Keys (CMK) Configuration
# Notice: Creation of custom KMS keys is disabled due to AWS Organizations
# Service Control Policy (SCP: arn:aws:organizations::989240880738:policy/o-jrnctys3et/service_control_policy/p-4rfqiutv)
# which explicitly denies kms:CreateKey.
# In accordance with enterprise multi-account best practices, the infrastructure
# utilizes AWS Managed Keys and AES-256 server-side encryption for ECR, Secrets
# Manager, and CloudWatch logs.
# ==============================================================================

# Custom KMS CMK commented out to adhere to organization SCP:
#
# resource "aws_kms_key" "app_cmk" {
#   description             = "Dedicated CMK for application secrets, logs, and container image encryption"
#   deletion_window_in_days = 30
#   enable_key_rotation     = true
#   ...
# }
