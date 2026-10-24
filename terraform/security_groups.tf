# ==============================================================================
# Security Groups: Strict Least-Privilege Network Isolation
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Application Load Balancer Security Group (Public Edge)
# ------------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-alb-sg"
  description = "Controls HTTPS access to the public Application Load Balancer"
  vpc_id      = aws_vpc.main.id

  # Inbound HTTP (port 80)
  ingress {
    description      = "Allow HTTP from anywhere"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  # Inbound HTTPS (port 443)
  ingress {
    description      = "Allow HTTPS from anywhere"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  # Egress ONLY to ECS Task Security Group on port 8080
  egress {
    description     = "Allow outbound to ECS tasks on application port"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-alb-sg"
  }
}

# ------------------------------------------------------------------------------
# 2. ECS Fargate Tasks Security Group (Private Compute)
# ------------------------------------------------------------------------------
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-${var.environment}-ecs-tasks-sg"
  description = "Controls ingress and egress for private ECS Fargate tasks"
  vpc_id      = aws_vpc.main.id

  # Ingress ONLY from ALB Security Group on container port
  ingress {
    description     = "Allow traffic strictly from ALB on container port"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Egress to VPC Endpoints for private AWS service communication
  egress {
    description     = "Allow HTTPS outbound to VPC endpoints"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.vpc_endpoints.id]
  }

  # Egress to PostgreSQL Database
  egress {
    description     = "Allow outbound connection to database"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.rds_database.id]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-ecs-tasks-sg"
  }
}

# ------------------------------------------------------------------------------
# 3. Amazon RDS Database Security Group (Isolated Data Layer)
# ------------------------------------------------------------------------------
resource "aws_security_group" "rds_database" {
  name        = "${var.project_name}-${var.environment}-rds-sg"
  description = "Controls access to PostgreSQL database from application tasks only"
  vpc_id      = aws_vpc.main.id

  # Ingress ONLY from ECS Task Security Group on port 5432
  ingress {
    description     = "Allow PostgreSQL access strictly from ECS tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  # No outbound rules needed for database
  tags = {
    Name = "${var.project_name}-${var.environment}-rds-sg"
  }
}

# ------------------------------------------------------------------------------
# 4. VPC Endpoints Security Group (PrivateLink)
# ------------------------------------------------------------------------------
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-${var.environment}-vpc-endpoints-sg"
  description = "Controls ingress to VPC Interface Endpoints from ECS tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Allow HTTPS from ECS tasks to AWS VPC Endpoints"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-sg"
  }
}
