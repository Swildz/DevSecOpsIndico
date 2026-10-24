# ==============================================================================
# Development Environment Configuration (dev.tfvars)
# Cost-optimized, single replica for rapid testing
# ==============================================================================

aws_region        = "ap-southeast-2"
environment       = "dev"
project_name      = "indico-api"
vpc_cidr          = "10.10.0.0/16"
public_subnet_cidrs      = ["10.10.1.0/24", "10.10.2.0/24"]
private_app_subnet_cidrs = ["10.10.10.0/24", "10.10.11.0/24"]
isolated_db_subnet_cidrs = ["10.10.20.0/24", "10.10.21.0/24"]

# Cost-optimized compute tier
desired_task_count = 1
fargate_cpu        = "256"
fargate_memory     = "512"

common_tags = {
  Project     = "indico-api"
  Environment = "dev"
  ManagedBy   = "Terraform"
  CostCenter  = "Engineering-Dev"
}
