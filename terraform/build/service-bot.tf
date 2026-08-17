resource "aws_ecs_task_definition" "bot" {
  family                   = "amster2k2x-${var.environment}-bot"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task_with_restore.arn

  # Explicitly configure Fargate to run on ARM64
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "postgres"
      image     = "postgres:16-alpine"
      essential = true
      environment = [
        { name = "POSTGRES_USER", value = "bot" },
        { name = "POSTGRES_PASSWORD", value = "test-only-not-secret" },
        { name = "POSTGRES_DB", value = "bot" }
      ]
      healthCheck = {
        command     = ["CMD-SHELL", "pg_isready -U bot || exit 1"]
        interval    = 10
        timeout     = 5
        retries     = 5
        startPeriod = 10
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs["bot"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "postgres"
        }
      }
    },
    {
      name      = "redis"
      image     = "redis:7-alpine"
      essential = true
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs["bot"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "redis"
        }
      }
    },
    {
      name      = "restore"
      image     = var.restore_helper_image
      essential = false
      dependsOn = [{ containerName = "postgres", condition = "HEALTHY" }]
      environment = [
        { name = "BACKUP_S3_BUCKET", value = data.terraform_remote_state.workload_account.outputs.backup_bucket_name },
        { name = "BACKUP_S3_KEY", value = "bot/latest.dump" },
        { name = "PGHOST", value = "localhost" },
        { name = "PGUSER", value = "bot" },
        { name = "PGPASSWORD", value = "test-only-not-secret" },
        { name = "PGDATABASE", value = "bot" }
      ]
      command = ["/restore.sh"]
      repositoryCredentials = {
        credentialsParameter = data.terraform_remote_state.workload_account.outputs.ghcr_pull_secret_arn
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs["bot"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "restore"
        }
      }
    },
    {
      name      = "bot"
      image     = var.bot_image
      essential = true
      dependsOn = [
        { containerName = "restore", condition = "COMPLETE" },
        { containerName = "redis", condition = "START" }
      ]
      # Single FastAPI server: webhooks, /health, and the cabinet's /api all
      # go through this one port per your .env.example comment.
      portMappings = [{ name = "bot", containerPort = var.bot_web_port, protocol = "tcp" }]
      environment = [
        { name = "DATABASE_MODE", value = "postgresql" },
        { name = "POSTGRES_HOST", value = "localhost" },
        { name = "POSTGRES_PORT", value = "5432" },
        { name = "POSTGRES_DB", value = "bot" },
        { name = "POSTGRES_USER", value = "bot" },
        { name = "POSTGRES_PASSWORD", value = "test-only-not-secret" },
        { name = "REDIS_URL", value = "redis://localhost:6379/0" },
        # Reaches panel over Service Connect, not through the public ALB.
        # Service Connect resolves "panel" within the namespace — no external ALB hairpin needed
        { name = "REMNAWAVE_API_URL", value = "http://panel:${var.panel_backend_port}" },
        { name = "REMNAWAVE_AUTH_TYPE", value = "api_key" },
        { name = "CABINET_ENABLED", value = "true" },
        { name = "CABINET_URL", value = "https://${data.terraform_remote_state.workload_account.outputs.hostname}" },
        { name = "CABINET_ALLOWED_ORIGINS", value = "https://${data.terraform_remote_state.workload_account.outputs.hostname}" }
      ]
      secrets = [
        { name = "BOT_TOKEN", valueFrom = data.terraform_remote_state.workload_account.outputs.bot_token_param_arn },
        { name = "REMNAWAVE_API_KEY", valueFrom = data.terraform_remote_state.workload_account.outputs.panel_api_token_param_arn },
        # TODO confirm exact var name — .env.example's bot healthcheck sends
        # this as X-API-Key; ALB target-group health checks can't send
        # custom headers, so see the note in outputs.tf / README re: this
        # target group possibly needing an unauthenticated health path instead.
        { name = "WEB_API_DEFAULT_TOKEN", valueFrom = data.terraform_remote_state.workload_account.outputs.bot_web_api_token_param_arn }
      ]
      healthCheck = {
        command = [
          "CMD-SHELL",
          "python -c \"import requests, os; requests.get('http://localhost:${var.bot_web_port}/health', headers={'X-API-Key': os.environ.get('WEB_API_DEFAULT_TOKEN')}, timeout=5) or exit(1)\""
        ]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 20
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
    },
    {
      name      = "cabinet"
      image     = var.cabinet_image
      essential = true
      dependsOn = [{ containerName = "bot", condition = "START" }]
      portMappings = [{ containerPort = var.cabinet_port, protocol = "tcp" }] # 80 — nginx-served static build
      repositoryCredentials = {
        credentialsParameter = data.terraform_remote_state.workload_account.outputs.ghcr_pull_secret_arn
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs["bot"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "cabinet"
        }
      }
    }
  ])
}

resource "aws_lb_target_group" "cabinet" {
  name        = "amster2k2x-${var.environment}-cabinet"
  port        = var.cabinet_port
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

resource "aws_lb_target_group" "bot" {
  name        = "amster2k2x-${var.environment}-bot"
  port        = var.bot_web_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  # The bot's /health requires X-API-Key which ALB can't send.
  # Health is determined solely by the ECS container-level healthCheck
  # (which does send the header). The ALB uses a permissive matcher so it
  # never marks the target unhealthy based on its own probe alone.
  health_check {
    path                = "/api/webhook"  # Telegram webhook endpoint — unauthenticated, returns 200 or 405
    matcher             = "200-499"       # Accept anything except 5xx; 405 (method not allowed on GET) is fine
    healthy_threshold   = 2
    unhealthy_threshold = 10              # Very forgiving — real health verdict comes from ECS, not here
    interval            = 30
    timeout             = 10
  }
}

# Cabinet's baked-in VITE_API_URL=/api needs this on the SAME port/origin
# cabinet is served from — this is that split, on the shared :80 listener.
resource "aws_lb_listener_rule" "bot_api" {
  listener_arn = aws_lb_listener.cabinet_https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.bot.arn
  }

  condition {
    path_pattern {
      values = ["/api*"]
    }
  }
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
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.web_services.id]
    assign_public_ip = true
  }

  # Two containers in this task, two separate ALB targets.
  load_balancer {
    target_group_arn = aws_lb_target_group.cabinet.arn
    container_name   = "cabinet"
    container_port   = var.cabinet_port
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.bot.arn
    container_name   = "bot"
    container_port   = var.bot_web_port
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn
  }

  depends_on = [aws_lb_listener.cabinet_https]
}
