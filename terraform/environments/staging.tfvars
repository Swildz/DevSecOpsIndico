# ==============================================================================
# Staging Environment Configuration (staging.tfvars)
# Pre-production environment for UAT, integration testing, and DAST scans
# ==============================================================================

aws_region        = "ap-southeast-2"
environment       = "staging"
project_name      = "indico-api"
vpc_cidr          = "10.20.0.0/16"
public_subnet_cidrs      = ["10.20.1.0/24", "10.20.2.0/24"]
private_app_subnet_cidrs = ["10.20.10.0/24", "10.20.11.0/24"]
isolated_db_subnet_cidrs = ["10.20.20.0/24", "10.20.21.0/24"]

# Staging compute configuration
desired_task_count = 1
fargate_cpu        = "256"
fargate_memory     = "512"

common_tags = {
  Project     = "indico-api"
  Environment = "staging"
  ManagedBy   = "Terraform"
  CostCenter  = "QA-Staging"
}
