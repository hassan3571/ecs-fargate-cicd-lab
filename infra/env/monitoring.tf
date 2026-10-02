# Alerts go to one SNS topic per environment:
#   - ALB 5xx errors from the targets
#   - Unhealthy targets in either target group
#   - High backend CPU
#   - Failed ECS deployments (circuit breaker triggered), via EventBridge

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${local.name}-target-5xx"
  alarm_description   = "Targets returned 5xx errors behind the ALB"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.this.arn_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  for_each = local.services

  alarm_name        = "${local.name}-${each.key}-unhealthy-targets"
  alarm_description = "At least one ${each.key} target is unhealthy"
  namespace         = "AWS/ApplicationELB"
  metric_name       = "UnHealthyHostCount"
  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = aws_lb_target_group.service[each.key].arn_suffix
  }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "backend_cpu_high" {
  alarm_name        = "${local.name}-backend-cpu-high"
  alarm_description = "Backend CPU above 80% for 5 minutes"
  namespace         = "AWS/ECS"
  metric_name       = "CPUUtilization"
  dimensions = {
    ClusterName = aws_ecs_cluster.this.name
    ServiceName = aws_ecs_service.service["backend"].name
  }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# --- Failed deployments ------------------------------------------------------
resource "aws_cloudwatch_event_rule" "deployment_failed" {
  name        = "${local.name}-deployment-failed"
  description = "ECS deployment failed (circuit breaker rollback)"

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Deployment State Change"]
    resources     = [for svc in aws_ecs_service.service : svc.id]
    detail = {
      eventName = ["SERVICE_DEPLOYMENT_FAILED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "deployment_failed" {
  rule      = aws_cloudwatch_event_rule.deployment_failed.name
  target_id = "sns"
  arn       = aws_sns_topic.alerts.arn
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "AllowCloudWatchAlarms"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "AllowEventBridgeDeploymentRule"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.deployment_failed.arn]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}
