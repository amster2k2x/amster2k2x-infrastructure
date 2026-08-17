output "deploy_role_arn" {
  value       = aws_iam_role.deploy.arn
  description = "Put this in the GitHub Environment secret AWS_DEPLOY_ROLE_ARN."
}

output "tfstate_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "tflock_table" {
  value = aws_dynamodb_table.tflock.name
}

output "backup_bucket_name" {
  value = aws_s3_bucket.golden_backups.bucket
}

output "backup_bucket_arn" {
  value = aws_s3_bucket.golden_backups.arn
}

output "ghcr_pull_secret_arn" {
  value = aws_secretsmanager_secret.ghcr_pull.arn
}

output "node_secret_key_param_arn" {
  value = aws_ssm_parameter.node_secret_key.arn
}

output "panel_app_secret_param_arn" {
  value = aws_ssm_parameter.panel_app_secret.arn
}

output "panel_api_token_param_arn" {
  value = aws_ssm_parameter.panel_api_token.arn
}

output "bot_token_param_arn" {
  value = aws_ssm_parameter.bot_token.arn
}

output "bot_web_api_token_param_arn" {
  value = aws_ssm_parameter.bot_web_api_token.arn
}

output "telegram_oidc_client_secret" {
  value = aws_ssm_parameter.telegram_oidc_client_secret.arn
}

output "ssm_parameter_path_prefix_arn" {
  value       = "arn:aws:ssm:${var.aws_region}:*:parameter/amster2k2x/${var.environment}/*"
  description = "Wildcard ARN covering all SSM params for this environment — used by build/'s execution-role policy."
}

output "cert_arn" {
  value = aws_acm_certificate.env.arn
}

output "acm_validation_cname" {
  value = {
    for dvo in aws_acm_certificate.env.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
  description = "Add this CNAME to Dynu once after first apply. Never changes."
}

output "hostname" {
  value = "${var.environment}.${var.base_domain}"
}
