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
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = data.terraform_remote_state.workload_account.outputs.ghcr_pull_secret_arn
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameters", "ssm:GetParameter"]
        Resource = data.terraform_remote_state.workload_account.outputs.ssm_parameter_path_prefix_arn
      }
    ]
  })
}

# --- Task role: used by the application code / entrypoint scripts at
# runtime. Only panel and bot need S3 access, for the golden-backup restore.
resource "aws_iam_role" "task_with_restore" {
  name               = "amster2k2x-${var.environment}-task-restore"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "task_restore_s3" {
  name = "read-golden-backups"
  role = aws_iam_role.task_with_restore.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        data.terraform_remote_state.workload_account.outputs.backup_bucket_arn,
        "${data.terraform_remote_state.workload_account.outputs.backup_bucket_arn}/*"
      ]
    }]
  })
}

# Required for ECS Exec / SSM port-forwarding into a running task — this is
# how you reach the panel/bot postgres containers to run save-golden-backup.sh
# without opening any inbound security group rule.
resource "aws_iam_role_policy" "task_ecs_exec" {
  name = "ecs-exec-session-manager"
  role = aws_iam_role.task_with_restore.id

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

# Subscription page and node don't touch S3 — plain task role, no extra policy.
resource "aws_iam_role" "task_plain" {
  name               = "amster2k2x-${var.environment}-task-plain"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}
