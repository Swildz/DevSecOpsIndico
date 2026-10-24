# ==============================================================================
# Application Load Balancer (ALB), Target Group, and AWS WAFv2 Integration
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. TLS Certificate Provisioning (Self-Signed Bootstrap if no ACM Cert given)
# ------------------------------------------------------------------------------
resource "tls_private_key" "alb_self_signed" {
  count     = var.certificate_arn == "" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb_self_signed" {
  count           = var.certificate_arn == "" ? 1 : 0
  private_key_pem = tls_private_key.alb_self_signed[0].private_key_pem

  subject {
    common_name  = "api.indico.internal"
    organization = "Indico DevSecOps"
  }

  validity_period_hours = 8760
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "alb_default" {
  count            = var.certificate_arn == "" ? 1 : 0
  private_key      = tls_private_key.alb_self_signed[0].private_key_pem
  certificate_body = tls_self_signed_cert.alb_self_signed[0].cert_pem

  tags = {
    Name = "${var.project_name}-${var.environment}-self-signed-acm"
  }
}

locals {
  effective_certificate_arn = var.certificate_arn != "" ? var.certificate_arn : aws_acm_certificate.alb_default[0].arn
}

# ------------------------------------------------------------------------------
# 2. Application Load Balancer (Public Edge)
# ------------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  drop_invalid_header_fields = true # Protection against HTTP desync & smuggle attacks

  tags = {
    Name = "${var.project_name}-${var.environment}-alb"
  }
}

# ------------------------------------------------------------------------------
# 3. ALB Target Group (Pointing to ECS Fargate)
# ------------------------------------------------------------------------------
resource "aws_lb_target_group" "app" {
  name        = "${var.project_name}-${var.environment}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/healthz"
    port                = tostring(var.container_port)
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-tg"
  }
}

# ------------------------------------------------------------------------------
# 4. HTTP Listener (Port 80) -> Redirects to HTTPS (Port 443)
# ------------------------------------------------------------------------------
resource "aws_lb_listener" "http_redirect" {
  #checkov:skip=CKV_AWS_2:ALB listener enforces HTTPS redirection
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ------------------------------------------------------------------------------
# 5. HTTPS Listener (Port 443) with Modern TLS Policy
# ------------------------------------------------------------------------------
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.effective_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ------------------------------------------------------------------------------
# 6. AWS WAFv2 Web ACL (Edge Layer 7 Security Filtering)
# ------------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "api_protection" {
  name        = "${var.project_name}-${var.environment}-waf"
  description = "WAF rules protecting backend API from OWASP Top 10 vulnerabilities"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Rule 1: AWS Managed Core Rule Set (CRS)
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: AWS Managed Known Bad Inputs Rule Set
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputsMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: AWS Managed Amazon IP Reputation List
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "IpReputationMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 4: Rate-Limiting Rule (Max 1000 requests per 5 minutes per IP)
  rule {
    name     = "RateLimitPerIP"
    priority = 40

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIPMetric"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-${var.environment}-waf-metrics"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-waf"
  }
}

# Associate WAF Web ACL with Application Load Balancer
resource "aws_wafv2_web_acl_association" "alb_waf" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.api_protection.arn
}
