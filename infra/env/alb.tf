# One public ALB for both services:
#   /api/*  -> backend target group
#   default -> frontend target group
# The browser talks to a single origin, so no CORS is needed.

resource "aws_lb" "this" {
  name               = local.name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  drop_invalid_header_fields = true
  # Lab setting. Turn on for production so the ALB cannot be deleted by mistake.
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "service" {
  for_each = local.services

  name                 = "${local.name}-${each.value.short}"
  port                 = each.value.port
  protocol             = "HTTP"
  target_type          = "ip" # required for Fargate (awsvpc networking)
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 30

  health_check {
    path                = each.value.health_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# --- HTTP only (no domain configured) -------------------------------------
resource "aws_lb_listener" "http_forward" {
  count = local.https_enabled ? 0 : 1

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service["frontend"].arn
  }
}

# --- HTTPS (domain configured): redirect 80 -> 443 ------------------------
resource "aws_lb_listener" "http_redirect" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
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

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service["frontend"].arn
  }
}

locals {
  app_listener_arn = local.https_enabled ? aws_lb_listener.https[0].arn : aws_lb_listener.http_forward[0].arn
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = local.app_listener_arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service["backend"].arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}
