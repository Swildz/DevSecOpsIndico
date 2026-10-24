# ==============================================================================
# Production Environment Configuration (production.tfvars)
# High-availability Multi-AZ, compliance-ready with 2+ task replicas
# ==============================================================================

aws_region        = "ap-southeast-2"
environment       = "production"
project_name      = "indico-api"
vpc_cidr          = "10.0.0.0/16"
public_subnet_cidrs      = ["10.0.1.0/24", "10.0.2.0/24"]
private_app_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]
isolated_db_subnet_cidrs = ["10.0.20.0/24", "10.0.21.0/24"]

# Production High Availability specs
desired_task_count = 2
fargate_cpu        = "512"
fargate_memory     = "1024"

common_tags = {
  Project      = "indico-api"
  Environment  = "production"
  ManagedBy    = "Terraform"
  Compliance   = "PCI-DSS-Ready"
  SecurityTier = "Confidential"
  CostCenter   = "Production-Core"
}
