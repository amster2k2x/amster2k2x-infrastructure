resource "aws_ecs_task_definition" "panel" {
  family                   = "amster2k2x-${var.environment}-panel"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task_app.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "backend"
      image     = var.panel_backend_image
      essential = true

      portMappings = [
        {
          # Named port — Service Connect uses this name to register the service
          name          = "panel"
          containerPort = var.panel_backend_port   # 3000
          protocol      = "tcp"
        },
        {
          name          = "panel-metrics"
          containerPort = var.panel_metrics_port   # 3001 — health only, not ALB traffic
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "APP_PORT",     value = tostring(var.panel_backend_port) },
        { name = "METRICS_PORT", value = tostring(var.panel_metrics_port) },

        # RDS — endpoint injected by Terraform, password via secrets below
        { name = "DB_HOST", value = aws_db_instance.main.address },
        { name = "DB_PORT", value = "5432" },
        { name = "DB_NAME", value = "remnawave_panel" },

        # ElastiCache — private endpoint, no auth required in this config
        { name = "REDIS_HOST", value = aws_elasticache_cluster.main.cache_nodes[0].address },
        { name = "REDIS_PORT", value = "6379" },

        # Public-facing domain URLs — host-based, no ports
        { name = "PANEL_DOMAIN",      value = "panel.${local.base_hostname}" },
        { name = "SUB_PUBLIC_DOMAIN", value = "sub.${local.base_hostname}/api/sub" },
        { name = "FRONT_END_DOMAIN",  value = "*" },

        { name = "METRICS_USER",                       value = "admin" },
        { name = "IS_TELEGRAM_NOTIFICATIONS_ENABLED",  value = "false" },
        { name = "WEBHOOK_ENABLED",                    value = "false" }
      ]

      secrets = [
        {
          # Full DATABASE_URL built and stored in Secrets Manager by data-tier.tf
          name      = "DATABASE_URL"
          valueFrom = aws_secretsmanager_secret.panel_db_url.arn
        },
        {
          name      = "APP_SECRET"
          valueFrom = data.terraform_remote_state.workload_account.outputs.panel_app_secret_param_arn
        },
        {
          name      = "METRICS_PASS"
          valueFrom = data.terraform_remote_state.workload_account.outputs.panel_app_secret_param_arn
        }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.panel_metrics_port}/health || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 30  # RDS is external — give the app time to connect on cold start
      }

      repositoryCredentials = {
        credentialsParameter = data.terraform_remote_state.workload_account.outputs.ghcr_pull_secret_arn
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs["panel"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "backend"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "panel" {
  name                   = "panel"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.panel.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  platform_version       = "LATEST"
  enable_execute_command = true

  network_configuration {
    subnets          = aws_subnet.private_app[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false  # NAT Gateway handles outbound
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.panel.arn
    container_name   = "backend"
    container_port   = var.panel_backend_port
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    service {
      port_name      = "panel"
      discovery_name = "panel"
      client_alias {
        port     = var.panel_backend_port
        dns_name = "panel.amster2k2x.local"  # matches arch doc internal DNS
      }
    }
  }

  depends_on = [aws_lb_listener.https]
}
