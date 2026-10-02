terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # One state file per environment (env/dev/..., env/prod/...), selected at
  # init time by the Infrastructure workflow (.github/workflows/infra.yml).
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name          = "${var.project}-${var.environment}"
  azs           = slice(data.aws_availability_zones.available.names, 0, 2)
  account_id    = data.aws_caller_identity.current.account_id
  https_enabled = var.domain_name != "" && var.hosted_zone_id != ""
  app_url       = local.https_enabled ? "https://${var.domain_name}" : "http://${aws_lb.this.dns_name}"
}
