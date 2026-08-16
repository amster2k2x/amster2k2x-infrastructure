variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

variable "test_account_id" {
  type        = string
  description = "AWS account ID of test-account (994939974695)."
  default     = "994939974695"
}

# variable "prod_account_id" {
#   type        = string
#   description = "AWS account ID of prod-account, once it exists."
# }

variable "github_trusted_subs" {
  type = list(string)
  description = <<-EOT
    GitHub OIDC 'sub' claim patterns allowed to assume this role.
    Environment-scoped (not branch-scoped), e.g.:
    "repo:Amster2k2x/vps-infrastructure:environment:test"
    Add one entry per repo+environment combination that should be able to deploy.
  EOT
}
