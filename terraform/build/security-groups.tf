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

  ingress {
    description = "HTTPS panel"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS subscription page"
    from_port   = 8082
    to_port     = 8082
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
resource "aws_security_group" "web_services" {
  name_prefix = "amster2k2x-${var.environment}-web-"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "From ALB only"
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

# Node: no ALB, no internet-facing access. Only reachable from the panel/bot
# tasks via Service Connect on the management port.
resource "aws_security_group" "node" {
  name_prefix = "amster2k2x-${var.environment}-node-"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Panel management connection only"
    from_port       = var.node_service_port
    to_port         = var.node_service_port
    protocol        = "tcp"
    security_groups = [aws_security_group.web_services.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # GHCR pulls — no VPN client traffic in this environment
  }

  lifecycle { create_before_destroy = true }
}
