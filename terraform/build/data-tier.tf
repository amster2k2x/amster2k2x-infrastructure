############################################
# data_tier.tf
# RDS PostgreSQL + ElastiCache Redis
# Both in isolated data subnets — no internet routing
############################################

############################################
# Subnet Groups
############################################

resource "aws_db_subnet_group" "main" {
  name       = "amster2k2x-${var.environment}-rds"
  subnet_ids = aws_subnet.data[*].id

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-rds-subnet-group"
  })
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "amster2k2x-${var.environment}-redis"
  subnet_ids = aws_subnet.data[*].id

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-redis-subnet-group"
  })
}

############################################
# RDS Master Password — random, stored in Secrets Manager
############################################

resource "random_password" "rds_master" {
  length           = 32
  special          = true
  override_special = "!$^&*()-_=[]{}|;:,.<>"
}

resource "aws_secretsmanager_secret" "rds_master" {
  name                    = "amster2k2x/${var.environment}/rds/master"
  description             = "RDS master credentials for amster2k2x ${var.environment}"
  recovery_window_in_days = 0 # ephemeral env — skip the 7-day recovery window

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-rds-master"
  })
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id
  secret_string = jsonencode({
    username = "postgres"
    password = random_password.rds_master.result
  })
}

############################################
# RDS PostgreSQL 16
# db.t4g.micro, 20 GB gp3, isolated subnet, not publicly accessible
# Two logical DBs provisioned post-apply via db-tools:
#   remnawave_panel  — Panel Task
#   remnawave_bot    — Bot Task
############################################

resource "aws_db_instance" "main" {
  identifier        = "amster2k2x-${var.environment}-pg"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "postgres" # default DB; remnawave_panel + remnawave_bot created by db-tools
  username = "postgres"
  password = random_password.rds_master.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible     = false # hard requirement — isolated subnet enforces this at network level too
  multi_az                = false # cost-optimised test env
  deletion_protection     = false # must be destroyable by terraform destroy
  skip_final_snapshot     = true  # ephemeral — backups go to S3 via db-tools, not RDS snapshots
  backup_retention_period = 0     # disable automated RDS backups; db-tools pg_dump covers this

  # Keep minor version patches automatic; major version pinned to 16
  auto_minor_version_upgrade = true

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-rds"
  })
}

############################################
# ElastiCache Redis 7
# cache.t4g.micro, isolated subnet
# Logical DB separation by index:
#   DB 0 — Panel (sessions + caching)
#   DB 1 — Bot (queues + state)
############################################

resource "aws_elasticache_cluster" "main" {
  cluster_id        = "amster2k2x-${var.environment}-redis"
  engine            = "redis"
  engine_version    = "7.1"
  node_type         = "cache.t4g.micro"
  num_cache_nodes   = 1 # single node — cost-optimised, no replication for test env
  port              = 6379

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.elasticache.id]

  # No auth token — access controlled entirely by SG (ecs_tasks only)
  # Panel uses DB 0, bot uses DB 1 — set in each service's env vars, not here

  apply_immediately = true # ephemeral env — no maintenance window concerns

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-redis"
  })
}

############################################
# Per-database connection URL secrets
# Consumed by panel and bot as DATABASE_URL env var.
# Built here where both the password and RDS endpoint are known.
############################################

resource "aws_secretsmanager_secret" "panel_db_url" {
  name                    = "amster2k2x/${var.environment}/rds/panel-db-url"
  description             = "Full DATABASE_URL for remnawave_panel — consumed by Panel Task"
  recovery_window_in_days = 0

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-panel-db-url"
  })
}

resource "aws_secretsmanager_secret_version" "panel_db_url" {
  secret_id = aws_secretsmanager_secret.panel_db_url.id

  # urlencode() handles any special characters in the password safely
  secret_string = "postgresql://postgres:${urlencode(random_password.rds_master.result)}@${aws_db_instance.main.address}:5432/remnawave_panel"
}

resource "aws_secretsmanager_secret" "bot_db_url" {
  name                    = "amster2k2x/${var.environment}/rds/bot-db-url"
  description             = "Full DATABASE_URL for remnawave_bot — consumed by Bot Task"
  recovery_window_in_days = 0

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-bot-db-url"
  })
}

resource "aws_secretsmanager_secret_version" "bot_db_url" {
  secret_id     = aws_secretsmanager_secret.bot_db_url.id
  secret_string = "postgresql://postgres:${urlencode(random_password.rds_master.result)}@${aws_db_instance.main.address}:5432/remnawave_bot"
}
