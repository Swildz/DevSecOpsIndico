# ==============================================================================
# Amazon ECR and Amazon ECS Fargate Infrastructure
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Amazon ECR Repository (Secure Image Storage)
# ------------------------------------------------------------------------------
resource "aws_ecr_repository" "app" {
  name                 = "${var.project_name}-${var.environment}-api"
  image_tag_mutability = "IMMUTABLE" # Prevents overwriting tags (Supply chain security)
  force_delete         = true        # Allows clean teardown during terraform destroy

  image_scanning_configuration {
    scan_on_push = true # Automated static vulnerability scan on upload
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-ecr"
  }
}

# Prune untagged and stale image layers to prevent bloat
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images older than 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 30 tagged production releases"
        selection = {
          tagStatus     = "any"
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# 2. Amazon ECS Cluster
# ------------------------------------------------------------------------------
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled" # Checkov & CIS Benchmark compliance
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-ecs-cluster"
  }
}

# ------------------------------------------------------------------------------
# 3. CloudWatch Log Group for Application Container
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "ecs_app_logs" {
  name              = "/ecs/${var.project_name}-${var.environment}"
  retention_in_days = 90

  tags = {
    Name = "${var.project_name}-${var.environment}-ecs-logs"
  }
}

# ------------------------------------------------------------------------------
# 4. ECS Fargate Task Definition (Hardened Security Constraints)
# ------------------------------------------------------------------------------
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project_name}-${var.environment}-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.fargate_cpu
  memory                   = var.fargate_memory
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "api-backend"
      image     = "${aws_ecr_repository.app.repository_url}:latest"
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      # Read-only root filesystem prevents container compromise from altering binaries
      readonlyRootFilesystem = true

      # Linux security hardening: Drop all capabilities
      linuxParameters = {
        capabilities = {
          drop = ["ALL"]
        }
      }

      # Mount ephemeral tmpfs volumes for necessary temporary files and socket cache
      mountPoints = [
        {
          sourceVolume  = "tmp-volume"
          containerPath = "/tmp"
          readOnly      = false
        }
      ]

      # Application environment variables (Non-sensitive)
      environment = [
        {
          name  = "ENVIRONMENT"
          value = var.environment
        },
        {
          name  = "PORT"
          value = tostring(var.container_port)
        }
      ]

      # Secrets dynamically fetched from AWS Secrets Manager via Task Execution Role
      secrets = [
        {
          name      = "DATABASE_CREDENTIALS"
          valueFrom = aws_secretsmanager_secret.db_credentials.arn
        }
      ]

      # Centralized logging to CloudWatch
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_app_logs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "api"
        }
      }

      # Container healthcheck for local container agent monitoring
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}/healthz || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }
    }
  ])

  # Ephemeral volume definition for read-only rootfs compliance
  volume {
    name = "tmp-volume"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-task-def"
  }
}

# ------------------------------------------------------------------------------
# 5. ECS Fargate Service (Multi-AZ High Availability Deployment)
# ------------------------------------------------------------------------------
resource "aws_ecs_service" "app" {
  name            = "${var.project_name}-${var.environment}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_task_count
  launch_type     = "FARGATE"

  # Force deployment to spread across distinct availability zones for resilience
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  network_configuration {
    # Place tasks strictly in private subnets with no public IPs
    subnets          = aws_subnet.private_app[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "api-backend"
    container_port   = var.container_port
  }

  # Ensure ALB listener and IAM role attachments are fully established first
  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.ecs_execution_attachment
  ]

  tags = {
    Name = "${var.project_name}-${var.environment}-ecs-service"
  }
}
