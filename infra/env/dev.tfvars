# Settings for the dev environment.
# project, aws_region and github_repo are passed by the Infrastructure workflow
# (from the PROJECT and AWS_REGION variables and the repository name).
environment = "dev"

vpc_cidr      = "10.10.0.0/16"
desired_count = 1
max_count     = 2
app_message   = "Hello from DEV (Parameter Store)"

enable_ecs_exec = true
alert_email     = "" # e.g. "you@example.com"

# Optional HTTPS: both must be set
domain_name    = "" # e.g. "dev.example.com"
hosted_zone_id = "" # e.g. "Z0123456789ABCDEFGHIJ"
