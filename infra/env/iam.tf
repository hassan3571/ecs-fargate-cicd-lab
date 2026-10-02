# Three kinds of roles, each with the minimum it needs:
#   1. Task execution role: used by ECS itself to pull images, write logs
#      and read this service's secrets at start-up.
#   2. Task role: used by the application code at runtime.
#   3. GitHub deploy role: assumed by GitHub Actions through OIDC, only from
#      a job running in the matching GitHub environment (dev or prod).

data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# --- 1. Execution role -----------------------------------------------------
resource "aws_iam_role" "execution" {
  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid       = "ReadThisEnvironmentSecretsOnly"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.api_secret.arn]
  }

  statement {
    sid       = "ReadThisEnvironmentParametersOnly"
    actions   = ["ssm:GetParameters"]
    resources = [aws_ssm_parameter.app_message.arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-app-config"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# --- 2. Task role (application permissions) ---------------------------------
# The demo app calls no AWS APIs, so the role is empty unless ECS Exec is on.
resource "aws_iam_role" "backend_task" {
  name               = "${local.name}-backend-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

data "aws_iam_policy_document" "ecs_exec" {
  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "backend_ecs_exec" {
  count  = var.enable_ecs_exec ? 1 : 0
  name   = "ecs-exec"
  role   = aws_iam_role.backend_task.id
  policy = data.aws_iam_policy_document.ecs_exec.json
}

# --- 3. GitHub Actions deploy role -----------------------------------------
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only a job that declares `environment: <dev|prod>` in this repository
    # gets a token with this subject. For prod, that job only runs after the
    # GitHub environment's required reviewers approve it.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:environment:${var.environment}"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name                 = "${local.name}-gha-deploy"
  assume_role_policy   = data.aws_iam_policy_document.github_deploy_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_deploy" {
  # These two actions do not support resource-level permissions.
  statement {
    sid       = "TaskDefinitions"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "UpdateThisEnvironmentServicesOnly"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [for svc in aws_ecs_service.service : svc.id]
  }

  statement {
    sid     = "PassOnlyThisEnvironmentTaskRoles"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.execution.arn,
      aws_iam_role.backend_task.arn,
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy-ecs"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}
