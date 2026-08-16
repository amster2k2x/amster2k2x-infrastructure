############################################
# BOOTSTRAP: workload account (test-account now, same file reused for
# prod-account later by re-applying with different vars/backend)
#
# Applied once per workload account, directly with that account's own admin
# credentials. Nothing here is ever destroyed by the ephemeral build/ pipeline.
#
# Creates:
#   - The cross-account role GitHub's hub role (in cicd-runner-account)
#     assumes to actually provision anything here
#   - The Terraform state bucket + lock table for the build/ layer
#   - ACM cert, S3 golden-backup bucket, GHCR pull secret, SSM app secrets —
#     everything that must survive a `terraform destroy` of build/
############################################

terraform {
  required_version = ">= 1.7"

  backend "s3" {
    # terraform init -backend-config=workload-account.tfbackend
    # State for THIS bootstrap layer. Created via one-time AWS CLI commands
    # in test-account — see BOOTSTRAP.md step 0b. Same bucket also holds
    # build/'s state, under a different key.
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "amster2k2x"
      Environment = var.environment
      ManagedBy   = "terraform"
      Layer       = "bootstrap-workload-account"
    }
  }
}

# ---------------------------------------------------------------------------
# Cross-account trust — only the cicd-runner-account hub role can assume this.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "hub_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.cicd_runner_account_id}:role/amster2k2x-cicd-hub"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "amster2k2x-${var.environment}-deploy"
  assume_role_policy = data.aws_iam_policy_document.hub_trust.json
}

resource "aws_iam_role_policy" "deploy_permissions" {
  name = "deploy-permissions"
  role = aws_iam_role.deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TerraformStateAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*"
        ]
      },
      {
        Sid      = "TerraformLock"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.tflock.arn
      },
      {
        Sid    = "ProvisionWorkloadInfra"
        Effect = "Allow"
        Action = [
          "ec2:*", "ecs:*", "elasticloadbalancing:*", "logs:*",
          "servicediscovery:*", "application-autoscaling:*"
        ]
        Resource = "*"
      },
      {
        Sid = "PassRolesToECS"
        Effect = "Allow"
        Action = [
          "iam:PassRole", "iam:CreateRole", "iam:DeleteRole", "iam:AttachRolePolicy",
          "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:GetRole", "iam:TagRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"
        ]
        Resource = "*"
      },
      {
        Sid      = "ReadGoldenBackups"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.golden_backups.arn, "${aws_s3_bucket.golden_backups.arn}/*"]
      },
      {
        Sid      = "ReadAppSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "ssm:GetParameter", "ssm:GetParameters"]
        Resource = "*"
      },
      {
        Sid      = "ECSExecForBackups"
        Effect   = "Allow"
        Action   = ["ecs:ExecuteCommand", "ssm:StartSession"]
        Resource = "*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Terraform state for build/ — lives in this account, not cicd-runner-account.
# Avoids cross-account S3/DynamoDB permission complexity: whichever role is
# actively running Terraform (the assumed deploy role, at that point) is
# already in the same account as the state bucket.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket_prefix = "amster2k2x-${var.environment}-tfstate-"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  name         = "amster2k2x-${var.environment}-tflock"
  hash_key     = "LockID"
  billing_mode = "PAY_PER_REQUEST"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# ---------------------------------------------------------------------------
# S3 — golden DB backups (panel + bot). Node needs none: it's stateless.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "golden_backups" {
  bucket = "amster2k2x-${var.environment}-golden-backups"
}

resource "aws_s3_bucket_versioning" "golden_backups" {
  bucket = aws_s3_bucket.golden_backups.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "golden_backups" {
  bucket                  = aws_s3_bucket.golden_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "golden_backups" {
  bucket = aws_s3_bucket.golden_backups.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

# ---------------------------------------------------------------------------
# ACM — issued once, DNS-validated once in Dynu, never re-requested.
# ---------------------------------------------------------------------------
resource "aws_acm_certificate" "env" {
  domain_name       = "${var.environment}.${var.base_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Secrets — created once here, values populated out-of-band. See BOOTSTRAP.md.
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "ghcr_pull" {
  name = "amster2k2x/${var.environment}/ghcr-pull"
}

resource "aws_ssm_parameter" "node_secret_key" {
  name  = "/amster2k2x/${var.environment}/node-secret-key"
  type  = "SecureString"
  value = "REPLACE_ME_MANUALLY"
  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "panel_app_secret" {
  name  = "/amster2k2x/${var.environment}/panel-app-secret"
  type  = "SecureString"
  value = "REPLACE_ME_MANUALLY"
  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "panel_api_token" {
  name  = "/amster2k2x/${var.environment}/panel-api-token"
  type  = "SecureString"
  value = "REPLACE_ME_MANUALLY"
  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "bot_token" {
  name  = "/amster2k2x/${var.environment}/bot-token"
  type  = "SecureString"
  value = "REPLACE_ME_MANUALLY"
  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "bot_web_api_token" {
  name  = "/amster2k2x/${var.environment}/bot-web-api-token"
  type  = "SecureString"
  value = "REPLACE_ME_MANUALLY"
  lifecycle { ignore_changes = [value] }
}
