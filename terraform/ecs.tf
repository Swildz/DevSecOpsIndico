# ==============================================================================
# Amazon ECR and Amazon ECS Fargate Infrastructure
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Amazon ECR Repository (Secure Image Storage)
# ------------------------------------------------------------------------------
resource "aws_ecr_repository" "app" {
  name                 = "${var.project_name}-${var.environment}-api"
  image_tag_mutability = "IMMUTABLE" # Prevents overwriting tags (Supply chain security)

  image_scanning_configuration {
    scan_on_push = true # Automated static vulnerability scan on upload
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.app_cmk.arn
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
  kms_key_id        = aws_kms_key.app_cmk.arn

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
  cpu                      = "512"
  memory                   = "1024"
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

      # Mount ephemeral scratch directory for temp writes
      mountPoints = [
        {
          sourceVolume  = "tmp_scratch"
          containerPath = "/tmp"
          readOnly      = false
        }
      ]

      # Native Secrets Manager integration (Decrypted dynamically by Fargate agent)
      secrets = [
        {
          name      = "DB_CONFIG"
          valueFrom = aws_secretsmanager_secret.db_credentials.arn
        }
      ]

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

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_app_logs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app"
        }
      }
    }
  ])

  volume {
    name = "tmp_scratch"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-task-def"
  }
}

# ------------------------------------------------------------------------------
# 5. ECS Fargate Service (Private Subnets, Zero Public IP)
# ------------------------------------------------------------------------------
resource "aws_ecs_service" "app" {
  name            = "${var.project_name}-${var.environment}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_task_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private_app[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false # Physical guarantee of zero direct public ingress
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "api-backend"
    container_port   = var.container_port
  }

  deployment_controller {
    type = "ECS"
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true # Automatic rollback on healthcheck failure
  }

  depends_on = [
    aws_lb_listener.http
  ]

  tags = {
    Name = "${var.project_name}-${var.environment}-service"
  }
}
