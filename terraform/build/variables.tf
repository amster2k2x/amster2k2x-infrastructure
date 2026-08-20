variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

variable "environment" {
  type        = string
  description = "test now, prod later. Drives all resource naming, the Service Connect namespace, and the hostname (<environment>.<base_domain>)."
  default     = "test"
}

variable "workload_account_state_bucket" {
  type        = string
  description = "S3 bucket holding bootstrap/workload-account's remote state (same account, output tfstate_bucket)."
}

variable "workload_account_state_key" {
  type    = string
  default = "bootstrap/terraform.tfstate"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC. Subnets are carved from this range."
  default     = "10.0.0.0/16"
}

# --- Image tags, supplied by the GitHub Actions run that triggered this apply ---
# Each defaults to :latest so `terraform plan` works standalone, but CI should
# always pass the exact digest/tag it just built and scanned.
variable "panel_backend_image" {
  type    = string
  default = "ghcr.io/amster2k2x/remnawave-backend:latest"
}

variable "bot_image" {
  type    = string
  default = "ghcr.io/amster2k2x/remnawave-bedolaga-telegram-bot:latest"
}

variable "cabinet_image" {
  type    = string
  default = "ghcr.io/amster2k2x/remnawave-bedolaga-cabinet:latest"
}

variable "subscription_page_image" {
  type    = string
  default = "ghcr.io/amster2k2x/remnawave-subscription-page:latest"
}

variable "node_image" {
  type    = string
  default = "ghcr.io/amster2k2x/remnawave-node:latest"
}

variable "db_tools_image" {
  type        = string
  description = "Image containing pg_dump, pg_restore, aws-cli and jq. Built and pushed to GHCR via CI pipeline."
  default     = "ghcr.io/amster2k2x/db-tools-image:latest"
}

# --- App-specific config you'll want to fill in once you share the compose files ---
variable "node_service_port" {
  type        = number
  description = "Port remnawave-node listens on for panel management traffic"
  default     = 2222
}

variable "panel_backend_port" {
  type    = number
  default = 3000 # APP_PORT
}

variable "panel_metrics_port" {
  type        = number
  default     = 3001 # METRICS_PORT - actual /health endpoint per your docker-compose
}

variable "bot_web_port" {
  type    = number
  default = 8080 # bot's single FastAPI server: webhooks, /health, cabinet API
}

variable "cabinet_port" {
  type        = number
  default     = 80 # static nginx build, per your wget healthcheck
}

variable "subscription_page_port" {
  type    = number
  default = 3010 # APP_PORT in subscription-page .env.sample
}

variable "bot_admin_ids" {
  type        = string
  description = "Comma-separated list of Telegram user IDs who are bot admins."
  default     = "59155651"
}