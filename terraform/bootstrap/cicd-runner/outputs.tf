output "hub_role_arn" {
  value       = aws_iam_role.hub.arn
  description = "Put this in the GitHub Environment secret AWS_HUB_ROLE_ARN."
}
