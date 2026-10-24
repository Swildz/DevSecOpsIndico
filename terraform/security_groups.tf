# ==============================================================================
# Security Groups: Strict Least-Privilege Network Isolation
# Using standalone aws_security_group_rule to break mutual dependency cycles
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Application Load Balancer Security Group (Public Edge)
# ------------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  #checkov:skip=CKV_AWS_260:Port 80 is required on public ALB to redirect traffic to HTTPS
  name        = "${var.project_name}-${var.environment}-alb-sg"
  description = "Controls HTTPS access to the public Application Load Balancer"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.environment}-alb-sg"
  }
}

resource "aws_security_group_rule" "alb_ingress_http" {
  #checkov:skip=CKV_AWS_260:Port 80 is required on public ALB to redirect traffic to HTTPS
  description       = "Allow HTTP from anywhere (redirected to HTTPS)"
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_ingress_https" {
  description       = "Allow HTTPS from anywhere"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_egress_to_ecs" {
  description              = "Allow outbound to ECS tasks on application port"
  type                     = "egress"
  from_port                = var.container_port
  to_port                  = var.container_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ecs_tasks.id
  security_group_id        = aws_security_group.alb.id
}

# ------------------------------------------------------------------------------
# 2. ECS Fargate Tasks Security Group (Private Compute)
# ------------------------------------------------------------------------------
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-${var.environment}-ecs-tasks-sg"
  description = "Controls ingress and egress for private ECS Fargate tasks"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.environment}-ecs-tasks-sg"
  }
}

resource "aws_security_group_rule" "ecs_ingress_from_alb" {
  description              = "Allow traffic strictly from ALB on container port"
  type                     = "ingress"
  from_port                = var.container_port
  to_port                  = var.container_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.ecs_tasks.id
}

resource "aws_security_group_rule" "ecs_egress_to_endpoints" {
  description              = "Allow HTTPS outbound to VPC endpoints"
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.vpc_endpoints.id
  security_group_id        = aws_security_group.ecs_tasks.id
}

resource "aws_security_group_rule" "ecs_egress_to_rds" {
  description              = "Allow outbound connection to database"
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.rds_database.id
  security_group_id        = aws_security_group.ecs_tasks.id
}

# ------------------------------------------------------------------------------
# 3. Amazon RDS Database Security Group (Isolated Data Layer)
# ------------------------------------------------------------------------------
resource "aws_security_group" "rds_database" {
  name        = "${var.project_name}-${var.environment}-rds-sg"
  description = "Controls access to PostgreSQL database from application tasks only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.environment}-rds-sg"
  }
}

resource "aws_security_group_rule" "rds_ingress_from_ecs" {
  description              = "Allow PostgreSQL access strictly from ECS tasks"
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ecs_tasks.id
  security_group_id        = aws_security_group.rds_database.id
}

# ------------------------------------------------------------------------------
# 4. VPC Endpoints Security Group (PrivateLink)
# ------------------------------------------------------------------------------
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-${var.environment}-vpc-endpoints-sg"
  description = "Controls ingress to VPC Interface Endpoints from ECS tasks"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-sg"
  }
}

resource "aws_security_group_rule" "vpce_ingress_from_ecs" {
  description              = "Allow HTTPS from ECS tasks to AWS VPC Endpoints"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ecs_tasks.id
  security_group_id        = aws_security_group.vpc_endpoints.id
}
