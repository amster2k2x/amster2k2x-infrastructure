resource "aws_ecs_cluster" "main" {
  name = "amster2k2x-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100
  }
}

# Service Connect namespace — gives the node a stable internal DNS name
# (node.<environment>) that survives every task replacement, so the panel's
# stored node address in its restored DB dump keeps working run after run.
resource "aws_service_discovery_http_namespace" "main" {
  name        = "amster2k2x.local"
  description = "ECS Service Connect namespace — internal DNS for ${var.environment}"
}

resource "aws_cloudwatch_log_group" "ecs" {
  for_each          = toset(["panel", "bot", "cabinet", "subscription", "node", "db-tools"])
  name              = "/ecs/amster2k2x-${var.environment}/${each.key}"
  retention_in_days = 7
}
