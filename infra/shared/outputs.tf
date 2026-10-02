output "ecr_repository_urls" {
  description = "ECR repository URLs, by service."
  value       = { for name, repo in aws_ecr_repository.app : name => repo.repository_url }
}

output "ecr_registry" {
  description = "ECR registry host (used for docker login)."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_push_role_arn" {
  description = "Put this in the GitHub repository variable AWS_ECR_PUSH_ROLE_ARN."
  value       = aws_iam_role.ecr_push.arn
}

output "github_oidc_provider_arn" {
  value = local.provider_arn
}
