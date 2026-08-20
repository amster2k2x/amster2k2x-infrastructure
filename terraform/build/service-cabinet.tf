resource "aws_ecs_task_definition" "cabinet" {
  family                   = "amster2k2x-${var.environment}-cabinet"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"   # nginx static file serving — minimal resources needed
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task_app.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "cabinet"
      image     = var.cabinet_image
      essential = true

      portMappings = [
        {
          name          = "cabinet"
          containerPort = var.cabinet_port  # 80 — nginx static build
          protocol      = "tcp"
        }
      ]

      # Cabinet is a pre-built static nginx image. VITE_API_URL is baked in
      # at build time as a relative path (/api), so the browser calls
      # https://bot.<hostname>/api/* which ALB routes to bot.
      # No environment variables or secrets needed at runtime.

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.cabinet_port}/ || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 10  # nginx starts fast — no DB connection to wait for
      }

      repositoryCredentials = {
        credentialsParameter = data.terraform_remote_state.workload_account.outputs.ghcr_pull_secret_arn
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs["cabinet"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "cabinet"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "cabinet" {
  name                   = "cabinet"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.cabinet.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  platform_version       = "LATEST"
  enable_execute_command = true

  network_configuration {
    subnets          = aws_subnet.private_app[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.cabinet.arn
    container_name   = "cabinet"
    container_port   = var.cabinet_port
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    # Registered for arch doc consistency — no other service currently calls
    # cabinet internally (browser JS calls public ALB directly).
    service {
      port_name      = "cabinet"
      discovery_name = "cabinet"
      client_alias {
        port     = var.cabinet_port
        dns_name = "cabinet.amster2k2x.local"
      }
    }
  }

  depends_on = [aws_lb_listener.https]
}
