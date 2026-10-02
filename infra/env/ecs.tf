locals {
  services = {
    backend = {
      short       = "be"
      port        = 3000
      health_path = "/api/health"
    }
    frontend = {
      short       = "fe"
      port        = 8080
      health_path = "/healthz"
    }
  }

  ecr_registry = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "service" {
  for_each          = local.services
  name              = "/ecs/${local.name}/${each.key}"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# Task definitions
# Terraform creates the first revision. After that, the pipeline registers
# new revisions (same family) with the new image tag.
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "backend" {
  family                   = "${local.name}-backend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.backend_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name                   = "backend"
      image                  = "${local.ecr_registry}/${var.project}-backend:${var.image_tag}"
      essential              = true
      readonlyRootFilesystem = true

      portMappings = [{ containerPort = 3000, protocol = "tcp" }]

      environment = [
        { name = "NODE_ENV", value = "production" },
        { name = "APP_ENV", value = var.environment },
        { name = "PORT", value = "3000" },
        { name = "APP_VERSION", value = var.image_tag },
      ]

      # Injected by ECS at start-up, using the execution role.
      secrets = [
        { name = "API_SECRET", valueFrom = aws_secretsmanager_secret.api_secret.arn },
        { name = "APP_MESSAGE", valueFrom = aws_ssm_parameter.app_message.arn },
      ]

      healthCheck = {
        command     = ["CMD", "node", "-e", "fetch('http://localhost:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.service["backend"].name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "backend"
        }
      }
    }
  ])
}

resource "aws_ecs_task_definition" "frontend" {
  family                   = "${local.name}-frontend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "frontend"
      image     = "${local.ecr_registry}/${var.project}-frontend:${var.image_tag}"
      essential = true

      portMappings = [{ containerPort = 8080, protocol = "tcp" }]

      healthCheck = {
        command     = ["CMD-SHELL", "wget -q --spider http://localhost:8080/healthz || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 5
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.service["frontend"].name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "frontend"
        }
      }
    }
  ])
}

locals {
  task_definition_arns = {
    backend  = aws_ecs_task_definition.backend.arn
    frontend = aws_ecs_task_definition.frontend.arn
  }
}

# ---------------------------------------------------------------------------
# Services: rolling deployments with the circuit breaker.
# If new tasks fail to become healthy, ECS stops the deployment and rolls
# back automatically to the last working task definition.
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "service" {
  for_each = local.services

  name            = each.key
  cluster         = aws_ecs_cluster.this.id
  task_definition = local.task_definition_arns[each.key]
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Keep full capacity during a deployment: start new tasks first,
  # stop old ones only once the new ones are healthy.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 30

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  enable_execute_command = each.key == "backend" ? var.enable_ecs_exec : false
  propagate_tags         = "SERVICE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.service[each.key].id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.service[each.key].arn
    container_name   = each.key
    container_port   = each.value.port
  }

  lifecycle {
    # The pipeline owns the running task definition, autoscaling owns the count.
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener_rule.api]
}

# ---------------------------------------------------------------------------
# Backend autoscaling on CPU
# ---------------------------------------------------------------------------
resource "aws_appautoscaling_target" "backend" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.service["backend"].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.desired_count
  max_capacity       = var.max_count
}

resource "aws_appautoscaling_policy" "backend_cpu" {
  name               = "${local.name}-backend-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.backend.service_namespace
  resource_id        = aws_appautoscaling_target.backend.resource_id
  scalable_dimension = aws_appautoscaling_target.backend.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 120
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
