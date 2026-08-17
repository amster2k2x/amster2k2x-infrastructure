resource "aws_ecs_task_definition" "panel" {
  family                   = "amster2k2x-${var.environment}-panel"
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
        { name = "POSTGRES_USER", value = "panel" },
        { name = "POSTGRES_PASSWORD", value = "test-only-not-secret" }, # TODO: move to Secrets Manager once you share prod env var names
        { name = "POSTGRES_DB", value = "panel" }
      ]
      healthCheck = {
        command     = ["CMD-SHELL", "pg_isready -U panel || exit 1"]
        interval    = 10
        timeout     = 5
        retries     = 5
        startPeriod = 10
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs["panel"].name
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
          "awslogs-group"         = aws_cloudwatch_log_group.ecs["panel"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "redis"
        }
      }
    },
    {
      # Waits for postgres to be healthy, pulls the golden dump from S3, restores it,
      # then exits. Backend below waits for this container to COMPLETE.
      # Needs a small helper image: see scripts/restore-helper.Dockerfile
      name         = "restore"
      image        = var.restore_helper_image
      essential    = false
      dependsOn    = [{ containerName = "postgres", condition = "HEALTHY" }]
      environment = [
        { name = "BACKUP_S3_BUCKET", value = data.terraform_remote_state.workload_account.outputs.backup_bucket_name },
        { name = "BACKUP_S3_KEY", value = "panel/latest.dump" },
        { name = "PGHOST", value = "localhost" },
        { name = "PGUSER", value = "panel" },
        { name = "PGPASSWORD", value = "test-only-not-secret" },
        { name = "PGDATABASE", value = "panel" }
      ]
      command = ["/restore.sh"]
      repositoryCredentials = {
        credentialsParameter = data.terraform_remote_state.workload_account.outputs.ghcr_pull_secret_arn
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs["panel"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "restore"
        }
      }
    },
    {
      name      = "backend"
      image     = var.panel_backend_image
      essential = true
      dependsOn = [
        { containerName = "restore", condition = "COMPLETE" },
        { containerName = "redis", condition = "START" }
      ]
      portMappings = [
        { name = "panel", containerPort = var.panel_backend_port, protocol = "tcp" },
        { containerPort = var.panel_metrics_port, protocol = "tcp" }
      ]
      environment = [
        { name = "APP_PORT", value = tostring(var.panel_backend_port) },
        { name = "METRICS_PORT", value = tostring(var.panel_metrics_port) },
        { name = "DATABASE_URL", value = "postgresql://panel:test-only-not-secret@localhost:5432/panel" },
        { name = "REDIS_HOST", value = "localhost" },
        { name = "REDIS_PORT", value = "6379" },
        { name = "PANEL_DOMAIN", value = "${data.terraform_remote_state.workload_account.outputs.hostname}:8081" },
        { name = "FRONT_END_DOMAIN", value = "*" },
        { name = "SUB_PUBLIC_DOMAIN", value = "${data.terraform_remote_state.workload_account.outputs.hostname}:8082/api/sub" },
        { name = "METRICS_USER", value = "admin" },
        { name = "IS_TELEGRAM_NOTIFICATIONS_ENABLED", value = "false" },
        { name = "WEBHOOK_ENABLED", value = "false" }
      ]
      secrets = [
        { name = "APP_SECRET", valueFrom = data.terraform_remote_state.workload_account.outputs.panel_app_secret_param_arn },
        { name = "METRICS_PASS", valueFrom = data.terraform_remote_state.workload_account.outputs.panel_app_secret_param_arn }
      ]
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.panel_metrics_port}/health || exit 1"]
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
          "awslogs-group"         = aws_cloudwatch_log_group.ecs["panel"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "backend"
        }
      }
    }
  ])
}

resource "aws_lb_target_group" "panel" {
  name        = "amster2k2x-${var.environment}-panel"
  port        = var.panel_backend_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/health"
    port                = var.panel_metrics_port # health lives on METRICS_PORT, not APP_PORT
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }
}

resource "aws_ecs_service" "panel" {
  name                   = "panel"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.panel.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  platform_version       = "LATEST"
  enable_execute_command = true # lets save-golden-backup.sh exec in via ECS Exec, no inbound SG rule needed

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.web_services.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.panel.arn
    container_name   = "backend"
    container_port   = var.panel_backend_port
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    # Server side: bot and subscription-page reach panel internally as
    # "panel.<environment>:3000" instead of hairpinning out through the public
    # ALB — same idea as node's own service block.
    service {
      port_name      = "panel"
      discovery_name = "panel"
      client_alias {
        port     = var.panel_backend_port
        dns_name = "panel"
      }
    }
  }

  depends_on = [aws_lb_listener.panel_https]
}
