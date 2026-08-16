resource "aws_lb" "main" {
  name               = "amster2k2x-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false
}

# ---------------------------------------------------------------------------
# Cabinet + bot (port 80 HTTP, 443 HTTPS)
# Cabinet is a root-serving SPA — it owns "/" on this listener.
# The /api prefix is split to the bot container on the same port.
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "cabinet_http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  # Redirect all HTTP → HTTPS
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "cabinet_https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.terraform_remote_state.workload_account.outputs.cert_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cabinet.arn
  }
}

# ---------------------------------------------------------------------------
# Panel (port 8081 HTTPS)
# Serves the remnawave admin frontend + backend API from its own listener so
# the SPA's root-relative assets don't break under a path prefix.
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "panel_https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 8081
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.terraform_remote_state.workload_account.outputs.cert_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.panel.arn
  }
}

# ---------------------------------------------------------------------------
# Subscription page (port 8082 HTTPS)
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "subscription_https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 8082
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.terraform_remote_state.workload_account.outputs.cert_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.subscription.arn
  }
}
