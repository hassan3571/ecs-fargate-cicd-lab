output "app_url" {
  description = "Put this in the GitHub environment variable APP_URL."
  value       = local.app_url
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "github_deploy_role_arn" {
  description = "Put this in the GitHub environment variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.github_deploy.arn
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "task_definition_families" {
  value = {
    backend  = aws_ecs_task_definition.backend.family
    frontend = aws_ecs_task_definition.frontend.family
  }
}

output "log_groups" {
  value = { for name, lg in aws_cloudwatch_log_group.service : name => lg.name }
}

output "secret_arn" {
  value = aws_secretsmanager_secret.api_secret.arn
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
