variable "project" {
  description = "Short project name used as a prefix for resource names."
  type        = string
  default     = "ecslab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.project))
    error_message = "Use 2-12 lowercase letters, digits or hyphens (ALB and target group names are limited to 32 characters)."
  }
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-west-3"
}

variable "github_repo" {
  description = "GitHub repository allowed to assume the roles, as owner/name (case-sensitive)."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "Use the format owner/repository."
  }
}
