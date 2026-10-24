# ==============================================================================
# Terraform Outputs
# ==============================================================================

output "vpc_id" {
  description = "The ID of the primary secure VPC"
  value       = aws_vpc.main.id
}

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "ecs_cluster_name" {
  description = "Name of the ECS Fargate cluster"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "Name of the backend ECS service"
  value       = aws_ecs_service.app.name
}

output "ecr_repository_url" {
  description = "Amazon ECR repository URL for pushing container images"
  value       = aws_ecr_repository.app.repository_url
}

output "kms_cmk_arn" {
  description = "Encryption mechanism used for data (AWS-managed keys enforced by SCP)"
  value       = "AWS-Managed Keys (AES-256 / AWS Managed KMS)"
}

output "secrets_manager_secret_arn" {
  description = "ARN of the application database secret in Secrets Manager"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "cicd_deployer_role_arn" {
  description = "ARN of the IAM role assumed by GitHub Actions / GitLab CI via OIDC"
  value       = aws_iam_role.cicd_deployer_role.arn
}
