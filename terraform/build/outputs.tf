output "alb_dns_name" {
  value       = aws_lb.main.dns_name
  description = "Point all Dynu subdomains (panel.*, sub.*, bot.*) as CNAMEs to this value."
}

output "panel_url" {
  value = "https://panel.${local.base_hostname}"
}

output "sub_url" {
  value = "https://sub.${local.base_hostname}"
}

output "bot_url" {
  value = "https://bot.${local.base_hostname}"
}

output "rds_endpoint" {
  value       = aws_db_instance.main.endpoint
  sensitive   = true
  description = "Written to SSM by GHA after apply, consumed by db-tools task as RDS_PRIVATE_ENDPOINT."
}

output "backups_bucket_name" {
  value       = data.terraform_remote_state.workload_account.outputs.backups_bucket_name
  description = "S3 bucket for the automated backup/restore cycle."
}
