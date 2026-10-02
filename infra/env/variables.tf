variable "project" {
  description = "Must match the project name used in infra/shared."
  type        = string
  default     = "ecslab"
}

variable "environment" {
  description = "Environment name. Must match the GitHub environment name (dev or prod)."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "aws_region" {
  type    = string
  default = "eu-west-3"
}

variable "github_repo" {
  description = "GitHub repository allowed to deploy to this environment, as owner/name (case-sensitive)."
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "image_tag" {
  description = "Image tag used when Terraform first creates the task definitions. The pipeline deploys new tags after that."
  type        = string
  default     = "initial"
}

variable "desired_count" {
  description = "Initial number of tasks per service (also the autoscaling minimum)."
  type        = number
  default     = 1
}

variable "max_count" {
  description = "Autoscaling maximum for the backend service."
  type        = number
  default     = 3
}

variable "app_message" {
  description = "Non-secret configuration stored in SSM Parameter Store."
  type        = string
  default     = "Hello from Parameter Store"
}

variable "enable_ecs_exec" {
  description = "Allow `aws ecs execute-command` into backend containers for troubleshooting."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email that receives CloudWatch alarms and failed-deployment alerts. Leave empty to skip."
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Optional, e.g. dev.example.com. With hosted_zone_id, enables HTTPS (ACM) and a Route 53 record."
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Optional Route 53 public hosted zone ID for domain_name."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  type    = number
  default = 14
}
