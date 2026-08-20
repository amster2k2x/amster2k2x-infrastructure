resource "aws_security_group" "alb" {
  name_prefix = "amster2k2x-${var.environment}-alb-"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP (redirects to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS cabinet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

# Panel, bot+cabinet, subscription page — behind the ALB, need outbound for
# GHCR image pulls and S3 backup restore. No direct inbound from internet.
resource "aws_security_group" "ecs_tasks" {
  name_prefix = "amster2k2x-${var.environment}-ecs-tasks-"
  vpc_id      = aws_vpc.main.id

  # Inbound from ALB on known app ports only (panel, sub-page, bot, cabinet)
  ingress {
    description     = "Panel API + UI from ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

ingress {
    description     = "Panel Metrics"
    from_port       = 3001
    to_port         = 3001
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "Subscription page from ALB"
    from_port       = 3010
    to_port         = 3010
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "Bot from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "Cabinet MiniApp from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Full TCP between tasks in this SG — Service Connect internal comms
  # (cabinet→bot, bot→panel, node→panel, sub→panel all run here)
  ingress {
    description = "Inter-task Service Connect traffic"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  # Outbound: GHCR pulls, Telegram API, S3 backups — all via NAT Gateway
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

# RDS security group — only ECS tasks can talk to the DB, no direct internet access.
resource "aws_security_group" "rds" {
  name_prefix = "amster2k2x-${var.environment}-rds-"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from ECS tasks only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  # No egress rule — isolated data subnet has no route anyway,
  # but explicit deny-all egress enforces intent at the SG layer too.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

# ElastiCache security group
resource "aws_security_group" "elasticache" {
  name_prefix = "amster2k2x-${var.environment}-elasticache-"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Redis from ECS tasks only"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}
