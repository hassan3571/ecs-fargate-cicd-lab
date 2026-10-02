# Shared resources used by every environment:
#   - ECR repositories (one image is built once and promoted dev -> prod)
#   - IAM role that GitHub Actions assumes to push images (main branch only)
# The GitHub OIDC provider itself is created once by bootstrap/bootstrap.yml.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # Configured at init time by the Infrastructure workflow (-backend-config).
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "shared"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  services     = ["backend", "frontend"]
  github_oidc  = "token.actions.githubusercontent.com"
  provider_arn = data.aws_iam_openid_connect_provider.github.arn
}

# Created by bootstrap/bootstrap.yml (only one can exist per account).
data "aws_iam_openid_connect_provider" "github" {
  url = "https://${local.github_oidc}"
}

# ---------------------------------------------------------------------------
# ECR repositories
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "app" {
  for_each = toset(local.services)

  name = "${var.project}-${each.key}"

  # Immutable tags: a tag (the git SHA) always points to the same image,
  # so what was tested in dev is exactly what reaches prod.
  image_tag_mutability = "IMMUTABLE"

  # Lab convenience: lets `terraform destroy` delete repos that contain images.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 30 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Role for the CI "build and push" job
# Trusted only for workflows running on the main branch of this repository.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecr_push_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc}:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "ecr_push" {
  name                 = "${var.project}-gha-ecr-push"
  assume_role_policy   = data.aws_iam_policy_document.ecr_push_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "ecr_push" {
  # GetAuthorizationToken does not support resource-level permissions.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushToProjectRepositoriesOnly"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for repo in aws_ecr_repository.app : repo.arn]
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.ecr_push.id
  policy = data.aws_iam_policy_document.ecr_push.json
}
