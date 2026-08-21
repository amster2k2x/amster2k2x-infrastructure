resource "aws_ecs_task_definition" "bot" {
  family                   = "amster2k2x-${var.environment}-bot"
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
      name      = "bot"
      image     = var.bot_image
      essential = true

      portMappings = [
        {
          name          = "bot"
          containerPort = var.bot_web_port  # 8080
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "ADMIN_IDS",    value = var.bot_admin_ids },
        { name = "BOT_RUN_MODE", value = "webhook" },
        { name = "DEBUG",        value = "true" },
        { name = "BOT_USERNAME", value = "amster2k2x_test_bot" },

        # Database — RDS managed, password via DATABASE_URL secret below
        { name = "DATABASE_MODE",  value = "postgresql" },
        { name = "POSTGRES_HOST",  value = aws_db_instance.main.address },
        { name = "POSTGRES_PORT",  value = "5432" },
        { name = "POSTGRES_DB",    value = "remnawave_bot" },
        { name = "POSTGRES_USER",  value = "postgres" },       # RDS master user

        # ElastiCache — DB index 1 reserved for bot
        { name = "REDIS_URL", value = "redis://${aws_elasticache_cluster.main.cache_nodes[0].address}:6379/1" },

        # Panel API — internal Service Connect DNS, never the public ALB
        { name = "REMNAWAVE_API_URL",  value = "http://panel.amster2k2x.local:${var.panel_backend_port}" },
        { name = "REMNAWAVE_AUTH_TYPE", value = "api_key" },

        # Cabinet — served at bot.* hostname (shares ALB domain with bot)
        { name = "CABINET_ENABLED",                    value = "true" },
        { name = "CABINET_URL",                        value = "https://bot.${local.base_hostname}" },
        { name = "CABINET_ALLOWED_ORIGINS",            value = "https://bot.${local.base_hostname}" },
        { name = "CABINET_ACCESS_TOKEN_EXPIRE_MINUTES", value = "60" },
        { name = "CABINET_REFRESH_TOKEN_EXPIRE_DAYS",  value = "30" },
        { name = "CABINET_EMAIL_VERIFICATION_ENABLED", value = "true" },

        # Telegram widget config
        { name = "TELEGRAM_WIDGET_SIZE",           value = "medium" },
        { name = "TELEGRAM_WIDGET_RADIUS",         value = "8" },
        { name = "TELEGRAM_WIDGET_USERPIC",        value = "true" },
        { name = "TELEGRAM_WIDGET_REQUEST_ACCESS", value = "true" },
        { name = "TELEGRAM_OIDC_ENABLED",          value = "true" },
        { name = "TELEGRAM_OIDC_CLIENT_ID",        value = "8029977831" },

        # Webhook — public URL Telegram calls back to
        { name = "WEBHOOK_URL", value = "https://bot.${local.base_hostname}/webhook" },

        # Web API (cabinet backend on same port)
        { name = "BACKUP_AUTO_ENABLED", value = "false" },
        { name = "WEB_API_ENABLED",     value = "true" },
        { name = "WEB_API_HOST",        value = "0.0.0.0" },
        { name = "WEB_API_PORT",        value = tostring(var.bot_web_port) }
      ]

      secrets = [
        {
          name      = "POSTGRES_PASSWORD"
          valueFrom = "${aws_secretsmanager_secret.rds_master.arn}:password::"
                                                                  # ↑ extracts only the password field
        },
        {
          name      = "BOT_TOKEN"
          valueFrom = data.terraform_remote_state.workload_account.outputs.bot_token_param_arn
        },
        {
          name      = "REMNAWAVE_API_KEY"
          valueFrom = data.terraform_remote_state.workload_account.outputs.panel_api_token_param_arn
        },
        {
          # Used by cabinet's /health and ALB health probe path
          name      = "WEB_API_DEFAULT_TOKEN"
          valueFrom = data.terraform_remote_state.workload_account.outputs.bot_web_api_token_param_arn
        },
        {
          name      = "TELEGRAM_OIDC_CLIENT_SECRET"
          valueFrom = data.terraform_remote_state.workload_account.outputs.telegram_oidc_client_secret_arn
        }
      ]

      # ECS container health check sends the API key header — ALB probe cannot,
      # so alb.tf uses a permissive matcher on an unauthenticated path instead.
      healthCheck = {
        command = [
          "CMD-SHELL",
          "python -c \"import requests, os; r=requests.get('http://localhost:${var.bot_web_port}/health', headers={'X-API-Key': os.environ.get('WEB_API_DEFAULT_TOKEN','')}, timeout=5); exit(0 if r.ok else 1)\""
        ]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 30  # RDS cold-connect on first start
      }

      repositoryCredentials = {
        credentialsParameter = data.terraform_remote_state.workload_account.outputs.ghcr_pull_secret_arn
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs["bot"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "bot"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "bot" {
  name                   = "bot"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.bot.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  platform_version       = "LATEST"
  enable_execute_command = true

  network_configuration {
    subnets          = aws_subnet.private_app[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  # Cabinet is a separate ECS service now — only one load_balancer block here
  load_balancer {
    target_group_arn = aws_lb_target_group.bot.arn
    container_name   = "bot"
    container_port   = var.bot_web_port
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    service {
      port_name      = "bot"
      discovery_name = "bot"
      client_alias {
        port     = var.bot_web_port
        dns_name = "bot.amster2k2x.local"
      }
    }
  }

  depends_on = [aws_lb_listener.https]
}
