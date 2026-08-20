data "terraform_remote_state" "workload_account" {
  backend = "s3"

  config = {
    bucket = var.workload_account_state_bucket
    key    = var.workload_account_state_key
    region = var.aws_region
  }
}

data "aws_caller_identity" "current" {}
