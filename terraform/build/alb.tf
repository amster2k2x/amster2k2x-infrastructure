locals {
  base_hostname = data.terraform_remote_state.workload_account.outputs.hostname
}

# ---------------------------------------------------------------------------
# ALB
# ---------------------------------------------------------------------------
resource "aws_lb" "main" {
  name                       = "amster2k2x-${var.environment}"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  enable_deletion_protection = false
}

# ---------------------------------------------------------------------------
# Listeners — single HTTP redirect + single HTTPS with host-based rules.
# Old port-per-service listeners (8081, 8082) are removed entirely.
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "http" {
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

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.terraform_remote_state.workload_account.outputs.cert_arn

  # Catch-all: nothing should reach this — all traffic is matched by rules below.
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

# ---------------------------------------------------------------------------
# Listener rules — lower priority number = evaluated first.
# panel and sub are unambiguous host matches.
# bot.* is split: /api/* and /webhook go to bot, /* falls through to cabinet.
# ---------------------------------------------------------------------------
resource "aws_lb_listener_rule" "panel" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.panel.arn
  }

  condition {
    host_header { values = ["panel.${local.base_hostname}"] } # matches arch doc internal DNS
  }
}

resource "aws_lb_listener_rule" "sub" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sub_page.arn
  }

  condition {
    host_header { values = ["sub.${local.base_hostname}"] }
  }
}

resource "aws_lb_listener_rule" "bot_api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 30

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.bot.arn
  }

  condition {
    host_header  { values = ["bot.${local.base_hostname}"] }
  }
  condition {
    path_pattern { values = ["/api/*"] }
  }
}

resource "aws_lb_listener_rule" "bot_webhook" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 31

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.bot.arn
  }

  condition {
    host_header  { values = ["bot.${local.base_hostname}"] }
  }
  condition {
    path_pattern { values = ["/webhook"] }
  }
}

resource "aws_lb_listener_rule" "cabinet" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 40

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cabinet.arn
  }

  condition {
    host_header { values = ["bot.${local.base_hostname}"] }
  }
}

# ---------------------------------------------------------------------------
# Target groups — one per service, ip mode for Fargate.
# deregistration_delay = 30 keeps teardown fast.
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "panel" {
  name        = "amster2k2x-${var.environment}-panel"
  port        = var.panel_backend_port # 3000 — traffic
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  deregistration_delay = 30

  health_check {
    port                = var.panel_metrics_port  # 3001 — health only
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

resource "aws_lb_target_group" "sub_page" {
  name        = "amster2k2x-${var.environment}-sub"
  port        = var.subscription_page_port  # 3010
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  deregistration_delay = 30

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

resource "aws_lb_target_group" "bot" {
  name        = "amster2k2x-${var.environment}-bot"
  port        = var.bot_web_port  # 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  deregistration_delay = 30

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

resource "aws_lb_target_group" "cabinet" {
  name        = "amster2k2x-${var.environment}-cabinet"
  port        = var.cabinet_port  # 3001
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  deregistration_delay = 30

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}
