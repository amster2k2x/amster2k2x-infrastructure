# ---------------------------------------------------------------------------
# db-tools — task definition ONLY, no ECS service.
# Launched on-demand by GitHub Actions via `aws ecs run-task` with a command
# override selecting either backup.sh or restore.sh. The task runs, completes,
# and exits — Fargate billing stops the moment it terminates.
#
# Launch pattern (from GitHub Actions workflow):
#   aws ecs run-task \
#     --cluster amster2k2x-${environment} \
#     --task-definition amster2k2x-${environment}-db-tools \
#     --launch-type FARGATE \
#     --network-configuration "awsvpcConfiguration={
#         subnets=[${private_app_subnet_ids}],
#         securityGroups=[${sg_ecs_tasks_id}],
#         assignPublicIp=DISABLED}" \
#     --overrides '{"containerOverrides":[{"name":"db-tools","command":["/scripts/backup.sh"]}]}'
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "db_tools" {
  family                   = "amster2k2x-${var.environment}-db-tools"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"  # pg_dump is I/O-bound, not CPU-bound
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task_db_tools.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "db-tools"
      image     = var.db_tools_image
      essential = true

      # No portMappings — this task never receives inbound connections.
      # No dependsOn — single container task.
      # Default command runs nothing; GitHub Actions always passes an override.
      command = ["/bin/sh", "-c", "echo 'No command override provided. Pass /scripts/backup.sh or /scripts/restore.sh via --overrides.'; exit 1"]

      environment = [
        # RDS endpoint injected by Terraform — scripts read this as $RDS_PRIVATE_ENDPOINT
        { name = "RDS_PRIVATE_ENDPOINT", value = aws_db_instance.main.address },

        # S3 bucket for backup/restore cycle — both scripts read $S3_BUCKET
        { name = "S3_BUCKET", value = "s3://${data.terraform_remote_state.workload_account.outputs.backups_bucket_name}" },

        # Database names — scripts use these to pg_dump/pg_restore correct DBs
        { name = "PANEL_DB_NAME", value = "remnawave_panel" },
        { name = "BOT_DB_NAME",   value = "remnawave_bot" },
        { name = "RDS_SECRET_ARN",       value = aws_secretsmanager_secret.rds_master.arn }  # ARN string, not secret contents
      ]

      secrets = []

      # No healthCheck — task runs to completion and exits.
      # ECS marks it healthy for the duration of execution by default.

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs["db-tools"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "db-tools"
        }
      }
    }
  ])
}

# ---------------------------------------------------------------------------
# Outputs consumed by GitHub Actions to construct the run-task call.
# ---------------------------------------------------------------------------
output "db_tools_task_definition_arn" {
  value       = aws_ecs_task_definition.db_tools.arn
  description = "Passed to --task-definition in aws ecs run-task."
}

output "private_app_subnet_ids" {
  value       = aws_subnet.private_app[*].id
  description = "Passed to awsvpcConfiguration.subnets in aws ecs run-task."
}

output "ecs_tasks_sg_id" {
  value       = aws_security_group.ecs_tasks.id
  description = "Passed to awsvpcConfiguration.securityGroups in aws ecs run-task."
}