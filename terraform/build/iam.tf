data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# --- Execution role: used by the ECS agent itself (pull image, fetch
# container-definition secrets, write logs). Same for every service.
resource "aws_iam_role" "execution" {
  name               = "amster2k2x-${var.environment}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  name = "read-pull-and-config-secrets"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Covers: ghcr-pull, rds/master, rds/panel-db-url, rds/bot-db-url,
        # and any future secrets added under this path.
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:amster2k2x/${var.environment}/*"
      },
      {
        Effect = "Allow"
        Action = ["ssm:GetParameters", "ssm:GetParameter"]
        Resource = data.terraform_remote_state.workload_account.outputs.ssm_parameter_path_prefix_arn
      }
    ]
  })
}

# Task role for all regular ECS services.
# ECS Exec enabled so you can docker exec into any running task for debugging
# without opening any inbound security group rule.
resource "aws_iam_role" "task_app" {
  name               = "amster2k2x-${var.environment}-task-app"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# Required for ECS Exec / SSM port-forwarding into a running task — this is
# how you reach the panel/bot postgres containers to run save-golden-backup.sh
# without opening any inbound security group rule.
resource "aws_iam_role_policy" "task_ecs_exec" {
  name = "ecs-exec-session-manager"
  role = aws_iam_role.task_app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}

# Task role for the ephemeral db-tools Fargate task only.
# Needs S3 read/write on the backup bucket and access to the RDS master
# secret so backup.sh / restore.sh can authenticate against PostgreSQL.
# No ECS Exec — the task exits on its own; interactive sessions don't apply.
resource "aws_iam_role" "task_db_tools" {
  name               = "amster2k2x-${var.environment}-task-db-tools"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "task_db_tools_s3" {
  name = "backups-bucket-access"
  role = aws_iam_role.task_db_tools.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = data.terraform_remote_state.workload_account.outputs.backups_bucket_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${data.terraform_remote_state.workload_account.outputs.backups_bucket_arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "task_db_tools_secrets" {
  name = "rds-master-secret-access"
  role = aws_iam_role.task_db_tools.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.rds_master.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*" 
      }
    ]
  })
}
