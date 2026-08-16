resource "aws_ecs_task_definition" "node" {
  family                   = "amster2k2x-${var.environment}-node"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task_plain.arn

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
      ]
      secrets = [
        { name = "NODE_SECRET_KEY", valueFrom = data.terraform_remote_state.workload_account.outputs.node_secret_key_param_arn }
      ]
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
  name             = "node"
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.node.arn
  desired_count    = 1
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.node.id]
    assign_public_ip = true # still needs a public IP to reach GHCR — no NAT gateway
  }

  # No load_balancer block at all: node is never reachable from the ALB/internet.
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    service {
      port_name      = "node"
      discovery_name = "node" # -> resolves as "node.<environment>" from the panel task
      client_alias {
        port     = var.node_service_port
        dns_name = "node"
      }
    }
  }
}
