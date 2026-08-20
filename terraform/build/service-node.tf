resource "aws_ecs_task_definition" "node" {
  family                   = "amster2k2x-${var.environment}-node"
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
      name      = "node"
      image     = var.node_image
      essential = true
      portMappings = [{
        name          = "node" # referenced by service_connect_configuration below
        containerPort = var.node_service_port
        protocol      = "tcp"
      }]
      environment = [
        # TODO: whatever remnawave-node needs besides the secret key — panel
        # callback URL etc, once you share the real env var names
        { name = "NODE_PORT", value = tostring(var.node_service_port) }
      ]
      secrets = [
        { name = "SECRET_KEY", valueFrom = data.terraform_remote_state.workload_account.outputs.node_secret_key_param_arn }
      ]
      healthCheck = {
        command     = ["CMD-SHELL", "curl -sf http://localhost:${var.node_service_port} > /dev/null 2>&1 || exit 0"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
      repositoryCredentials = {
        credentialsParameter = data.terraform_remote_state.workload_account.outputs.ghcr_pull_secret_arn
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs["node"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "node"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "node" {
  name                   = "node"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.node.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  platform_version       = "LATEST"
  enable_execute_command = true  # add

  network_configuration {
    subnets          = aws_subnet.private_app[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false # NAT handles outbound now
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    service {
      port_name      = "node"
      discovery_name = "node"
      client_alias {
        port     = var.node_service_port
        dns_name = "node.amster2k2x.local"
      }
    }
  }
}
