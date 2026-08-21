resource "aws_ecs_task_definition" "subscription" {
  family                   = "amster2k2x-${var.environment}-subscription"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task_app.arn
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
      portMappings = [
        {
          name          = "sub"
          containerPort = var.subscription_page_port
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "APP_PORT", value = tostring(var.subscription_page_port) },
        # Reaches panel over Service Connect, not through the public ALB.
        # Reaches panel via Service Connect (internal, no HTTPS needed within VPC)
        { name = "REMNAWAVE_PANEL_URL", value = "http://panel.amster2k2x.local:${var.panel_backend_port}" },
        { name = "META_TITLE", value = "Amster2k2x Subscription Test" },
        { name = "META_DESCRIPTION", value = "Amster2k2x Test subscription page" },
        { name = "TRUST_PROXY", value = "1" }, # behind the ALB
        { name = "CUSTOM_SUB_PREFIX", value = "" } # owns root of its own listener port, no prefix needed
      ]
      secrets = [
        { name = "REMNAWAVE_API_TOKEN", valueFrom = data.terraform_remote_state.workload_account.outputs.panel_api_token_param_arn }
      ]
      healthCheck = {
        command     = ["CMD-SHELL", "curl -fs -o /dev/null --max-time 2 http://localhost:${var.subscription_page_port}/internal/health || exit 1"]
        interval    = 30
        timeout     = 3
        retries     = 3
        startPeriod = 20
      }
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

resource "aws_ecs_service" "subscription" {
  name                   = "subscription"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.subscription.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  platform_version       = "LATEST"
  enable_execute_command = true  # add

  depends_on = [
    aws_lb_listener.https,
    aws_ecs_service.panel # Wait for panel to reach steady state first
  ]

  network_configuration {
    subnets          = aws_subnet.private_app[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.sub_page.arn
    container_name   = "subscription-page"
    container_port   = var.subscription_page_port
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    service {                                            # add entire block
      port_name      = "sub"
      discovery_name = "sub"
      client_alias {
        port     = var.subscription_page_port
        dns_name = "sub.amster2k2x.local"
      }
    }
  }

  depends_on = [aws_lb_listener.https]
}
