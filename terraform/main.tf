# ==============================================================================
# Main Terraform Configuration: Providers and Backend
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.30.0"
    }
  }

  # Production remote backend configuration with state encryption and DynamoDB locking
  # backend "s3" {
  #   bucket         = "indico-terraform-state-prod"
  #   key            = "backend-api/terraform.tfstate"
  #   region         = "ap-southeast-1"
  #   encrypt        = true
  #   dynamodb_table = "indico-terraform-locks"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      var.common_tags,
      {
        Environment = var.environment
        DeployedAt  = "Terraform"
      }
    )
  }
}

# Current Account and Region Data Sources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}
