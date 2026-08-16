variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

variable "environment" {
  type        = string
  description = "Environment name: test now, prod later. Drives all resource naming."
  default     = "test"
}

variable "cicd_runner_account_id" {
  type        = string
  description = "AWS account ID of cicd-runner-account (111194324950) — the only account allowed to assume this account's deploy role."
  default     = "111194324950"
}

variable "base_domain" {
  type    = string
  default = "amster2k2x.mywire.org"
}
