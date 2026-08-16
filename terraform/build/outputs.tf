output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "hostname" {
  value = data.terraform_remote_state.workload_account.outputs.hostname
}

output "cabinet_url" {
  value = "https://${data.terraform_remote_state.workload_account.outputs.hostname}"
}

output "panel_url" {
  value = "https://${data.terraform_remote_state.workload_account.outputs.hostname}:8081"
}

output "subscription_url" {
  value = "https://${data.terraform_remote_state.workload_account.outputs.hostname}:8082"
}
