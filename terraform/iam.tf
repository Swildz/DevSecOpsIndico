# ==============================================================================
# AWS IAM Least-Privilege Roles and Policies
# Roles: 1. ECS Task Execution Role, 2. ECS Task Role, 3. CI/CD OIDC Deployment Role
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. ECS Task Execution Role (Used by AWS Fargate Agent)
# ------------------------------------------------------------------------------
resource "aws_iam_role" "ecs_execution_role" {
  name        = "${var.project_name}-${var.environment}-ecs-execution-role"
  description = "Assumed by ECS agent to pull images and inject secrets at startup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECSTaskExecutionAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Standard ECR Pull & CloudWatch Logs Policy
resource "aws_iam_role_policy_attachment" "ecs_execution_standard" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Scoped Policy: Get Application Secrets from Secrets Manager
resource "aws_iam_policy" "ecs_secrets_access" {
  name        = "${var.project_name}-${var.environment}-secrets-retrieval-policy"
  description = "Allows ECS agent to retrieve specific application secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GetApplicationDatabaseSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.db_credentials.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_secrets_attachment" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = aws_iam_policy.ecs_secrets_access.arn
}

# ------------------------------------------------------------------------------
# 2. ECS Task Role (Used by Application Runtime Code Inside Container)
# ------------------------------------------------------------------------------
resource "aws_iam_role" "ecs_task_role" {
  name        = "${var.project_name}-${var.environment}-ecs-task-role"
  description = "Assumed by application runtime code inside container"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECSTaskAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Example minimal runtime permissions (e.g. read/write to application S3 bucket)
resource "aws_iam_policy" "ecs_task_app_permissions" {
  name        = "${var.project_name}-${var.environment}-task-app-policy"
  description = "Application business logic permissions at runtime"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyPrivilegeEscalation"
        Effect = "Deny"
        Action = [
          "iam:*",
          "organizations:*"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_attachment" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.ecs_task_app_permissions.arn
}

# ------------------------------------------------------------------------------
# GitHub Actions OpenID Connect (OIDC) Identity Provider
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a2a97ac93e75741154a00afb2b2e5f65ff52"]
}

# ------------------------------------------------------------------------------
# 3. CI/CD Pipeline Deployment Role (GitHub Actions / GitLab CI via OIDC)
# Eliminates long-lived static AWS access keys entirely!
# ------------------------------------------------------------------------------
resource "aws_iam_role" "cicd_deployer_role" {
  name        = "${var.project_name}-${var.environment}-cicd-deployer-role"
  description = "Assumed by GitHub Actions via OIDC with short-lived tokens"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubActionsOIDCAssumeRole"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:refs/heads/main"
          }
        }
      }
    ]
  })
}

# Least-Privilege Scoped Policy for CI/CD Deployment
resource "aws_iam_policy" "cicd_deployer_policy" {
  name        = "${var.project_name}-${var.environment}-cicd-deployer-policy"
  description = "Scoped permissions strictly required to build, scan, and deploy container"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ECR Authentication & Push permissions
      {
        Sid    = "ECRAuthToken"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRImageManagement"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = [
          aws_ecr_repository.app.arn
        ]
      },
      # ECS Deployment permissions (Only on designated cluster and service)
      {
        Sid    = "ECSDeploymentControl"
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:UpdateService"
        ]
        Resource = [
          aws_ecs_service.app.id
        ]
      },
      {
        Sid    = "ECSTaskRegistration"
        Effect = "Allow"
        Action = [
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeTaskDefinition"
        ]
        Resource = "*"
      },
      # PassRole strictly restricted to the ECS Execution and Task Roles
      {
        Sid    = "PassRoleToECSAgent"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          aws_iam_role.ecs_execution_role.arn,
          aws_iam_role.ecs_task_role.arn
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cicd_deployer_attachment" {
  role       = aws_iam_role.cicd_deployer_role.name
  policy_arn = aws_iam_policy.cicd_deployer_policy.arn
}
