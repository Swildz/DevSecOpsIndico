# ==============================================================================
# Terraform Variables Definitions
# ==============================================================================

variable "aws_region" {
  description = "The AWS Region where resources will be deployed"
  type        = string
  default     = "ap-southeast-1"
}

variable "environment" {
  description = "Deployment environment name (e.g., dev, staging, production)"
  type        = string
  default     = "production"
  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be one of: dev, staging, production."
  }
}

variable "project_name" {
  description = "Base project identifier used for resource naming and tagging"
  type        = string
  default     = "indico-api"
}

variable "vpc_cidr" {
  description = "The CIDR block allocated to the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (hosting ALB)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for private application subnets (hosting ECS Fargate)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "isolated_db_subnet_cidrs" {
  description = "CIDR blocks for isolated database subnets (hosting RDS PostgreSQL)"
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}

variable "container_port" {
  description = "Port exposed by the backend application container"
  type        = number
  default     = 8080
}

variable "desired_task_count" {
  description = "Number of ECS Fargate task replicas to run"
  type        = number
  default     = 2
}

variable "certificate_arn" {
  description = "Optional ACM Certificate ARN for HTTPS listener. If empty, ALB listens on HTTP port 80."
  type        = string
  default     = ""
}

variable "github_repository" {
  description = "GitHub repository formatted as 'owner/repo' for OIDC trust condition"
  type        = string
  default     = "Swildz/DevSecOpsIndico"
}

variable "common_tags" {
  description = "Common baseline tags applied to all AWS infrastructure resources"
  type        = map(string)
  default = {
    Project     = "indico-api"
    Environment = "production"
    ManagedBy   = "Terraform"
    Compliance  = "PCI-DSS-Ready"
    SecurityTier= "Confidential"
  }
}
