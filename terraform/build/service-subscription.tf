resource "aws_ecs_task_definition" "subscription" {
  family                   = "amster2k2x-${var.environment}-subscription"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task_plain.arn
  # Explicitly configure Fargate to run on ARM64
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name         = "subscription-page"
      image        = var.subscription_page_image
      essential    = true
      portMappings = [{ containerPort = var.subscription_page_port, protocol = "tcp" }]
      environment = [
        { name = "APP_PORT", value = tostring(var.subscription_page_port) },
        # Reaches panel over Service Connect, not through the public ALB.
        # Reaches panel via Service Connect (internal, no HTTPS needed within VPC)
        { name = "REMNAWAVE_PANEL_URL", value = "http://panel:${var.panel_backend_port}" },
        { name = "TRUST_PROXY", value = "1" }, # behind the ALB
        { name = "CUSTOM_SUB_PREFIX", value = "" } # owns root of its own listener port, no prefix needed
      ]
      secrets = [
        { name = "REMNAWAVE_API_TOKEN", valueFrom = data.terraform_remote_state.workload_account.outputs.panel_api_token_param_arn }
      ]
      repositoryCredentials = {
        credentialsParameter = data.terraform_remote_state.workload_account.outputs.ghcr_pull_secret_arn
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs["subscription"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "subscription-page"
        }
      }
    }
  ])
}

resource "aws_lb_target_group" "subscription" {
  name        = "amster2k2x-${var.environment}-sub"
  port        = var.subscription_page_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }
}

resource "aws_ecs_service" "subscription" {
  name             = "subscription"
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.subscription.arn
  desired_count    = 1
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.web_services.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.subscription.arn
    container_name   = "subscription-page"
    container_port   = var.subscription_page_port
  }

  depends_on = [aws_lb_listener.subscription_https]
}
