# Settings for the prod environment.
# project, aws_region and github_repo are passed by the Infrastructure workflow
# (from the PROJECT and AWS_REGION variables and the repository name).
environment = "prod"

vpc_cidr      = "10.20.0.0/16"
desired_count = 2
max_count     = 4
app_message   = "Hello from PROD (Parameter Store)"

enable_ecs_exec = false
alert_email     = "" # e.g. "you@example.com"

# Optional HTTPS: both must be set
domain_name    = "" # e.g. "app.example.com"
hosted_zone_id = "" # e.g. "Z0123456789ABCDEFGHIJ"
