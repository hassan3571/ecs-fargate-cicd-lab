# Runbook

Day-to-day operations for the ECS Fargate deployment. Most tasks are done from
GitHub Actions or the AWS Console. The command-line examples run in **AWS CloudShell**
(the `>_` icon in the AWS Console), which already has the AWS CLI: nothing to install.
Replace `ecslab` with your project name and `dev` with the environment.

```bash
export PROJECT=ecslab ENV=dev AWS_REGION=eu-west-3
export CLUSTER=$PROJECT-$ENV
```

---

## 1. How to deploy

**Normal path:** merge a pull request into `main`.

1. CI runs (tests, builds, scans, Terraform checks).
2. Both images are built once, scanned, and pushed to ECR with the commit SHA as tag.
3. Dev is deployed and smoke-tested (`/api/info` must return the new SHA).
4. Prod waits for approval: **Actions → the run → Review deployments → Approve**.
5. Prod is deployed with the same images, then smoke-tested.

**Redeploy the same commit:** Actions → Deploy → Run workflow (images already in
ECR are reused, not rebuilt).

**Infrastructure changes** (CPU/memory, new env var or secret, alarms): edit the
Terraform files or `infra/env/<env>.tfvars` through a pull request, merge, then run
**Actions → Infrastructure** with the stack and action `plan` (check the summary),
then `apply`.

Terraform registers a new task definition revision; the next pipeline deployment
picks it up (the pipeline always starts from the latest revision).

---

## 2. How to roll back

**Automatic:** if new tasks fail their health checks, the ECS deployment
circuit breaker stops the deployment and returns to the last working revision.
The GitHub job fails and an alert is sent to the SNS topic.

**Manual (recommended):** Actions → **Rollback** → Run workflow → choose
environment and service. Leave *revision* empty to go back one revision, or
enter a specific one. Prod rollbacks also need approval.

**Manual (CLI, emergency):**

```bash
# List recent revisions and the image each one uses
for rev in $(aws ecs list-task-definitions --family-prefix $CLUSTER-backend \
  --sort DESC --max-items 5 --query 'taskDefinitionArns[]' --output text); do
  echo "$rev -> $(aws ecs describe-task-definition --task-definition $rev \
    --query 'taskDefinition.containerDefinitions[0].image' --output text)"
done

aws ecs update-service --cluster $CLUSTER --service backend \
  --task-definition $CLUSTER-backend:<REVISION>
aws ecs wait services-stable --cluster $CLUSTER --services backend
```

After a rollback, fix forward with a new commit. The next deployment from
`main` will replace the rolled-back version.

---

## 3. How to troubleshoot a failed deployment

Start with the service events: they usually name the problem.

```bash
aws ecs describe-services --cluster $CLUSTER --services backend \
  --query 'services[0].events[:10].[createdAt,message]' --output table

# Why did the last tasks stop?
aws ecs list-tasks --cluster $CLUSTER --service-name backend --desired-status STOPPED \
  --query 'taskArns[:3]' --output text | xargs -r aws ecs describe-tasks --cluster $CLUSTER \
  --query 'tasks[].[stoppedReason,containers[0].reason,containers[0].exitCode]' --tasks

# Application logs (last 15 minutes)
aws logs tail /ecs/$CLUSTER/backend --since 15m --follow
```

| Symptom | Likely cause | Fix |
|---|---|---|
| GitHub: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The token subject does not match the role trust policy | Check `github_repo` in tfvars (case-sensitive), the GitHub environment name (`dev`/`prod`), and that push jobs run on `main`. |
| `CannotPullContainerError` | Image tag not in ECR, or no outbound HTTPS | Check the tag exists in ECR; check the NAT gateway and the task security group egress rule. |
| `ResourceInitializationError: unable to pull secrets` | Execution role cannot read the secret/parameter, or no outbound HTTPS | Check the execution role policy ARNs and network egress. |
| Tasks start, then stop; targets "unhealthy" | Health check path/port wrong, app crashing | Check the target group health check, `aws logs tail`, run the image locally. |
| `Essential container in task exited` | App error at start-up | Read the logs; run the same image locally with the same env vars. |
| Push fails: `tag invalid ... already exists` | ECR tags are immutable | Expected: the workflow skips existing images. Never retag; build a new commit. |
| Smoke test fails but deployment succeeded | ALB still draining old tasks, or wrong `APP_URL` | Check `APP_URL` in the GitHub environment; rerun the job. |
| Circuit breaker rolled back | New version unhealthy | Read stopped-task reasons and logs; fix and push a new commit. |

**Get a shell in a running backend container** (dev, `enable_ecs_exec = true`,
requires the Session Manager plugin locally):

```bash
TASK=$(aws ecs list-tasks --cluster $CLUSTER --service-name backend --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster $CLUSTER --task $TASK --container backend --interactive --command "/bin/sh"
```

**Useful CloudWatch Logs Insights query** (log group `/ecs/<cluster>/backend`):

```
fields @timestamp, method, path, status, duration_ms
| filter msg = "request" and status >= 500
| sort @timestamp desc
| limit 50
```

---

## 4. How to manage secrets and configuration

| Type | Where | Example | Who can read it |
|---|---|---|---|
| Sensitive | Secrets Manager `<project>-<env>/backend/...` | API keys, DB passwords | The environment's ECS execution role only |
| Non-sensitive | Parameter Store `/<project>/<env>/backend/...` | Feature flags, messages, URLs | The environment's ECS execution role only |
| Pipeline settings | GitHub repository and environment **variables** | Role ARNs, region, app URL | GitHub Actions |

No AWS access keys exist anywhere: GitHub uses OIDC to get short-lived credentials.

**Change a secret value** (containers read secrets only at start-up, so restart them):

```bash
aws secretsmanager put-secret-value --secret-id $CLUSTER/backend/api-secret \
  --secret-string "$(openssl rand -hex 20)"
aws ecs update-service --cluster $CLUSTER --service backend --force-new-deployment
```

Never pass a secret on the command line in shared terminals or CI logs; use a
file or an interactive prompt in real use.

**Change a parameter:** edit `app_message` in `<env>.tfvars` and apply, or for a
quick test:

```bash
aws ssm put-parameter --name /$PROJECT/$ENV/backend/APP_MESSAGE --value "New text" --overwrite
aws ecs update-service --cluster $CLUSTER --service backend --force-new-deployment
```

(Terraform will set it back to the tfvars value on the next apply.)

**Add a new secret:** add an `aws_secretsmanager_secret` in `infra/env/secrets.tf`,
add its ARN to the execution role policy in `iam.tf`, add it to the container's
`secrets` list in `ecs.tf`, apply, then deploy.

---

## 5. How to maintain the infrastructure

- **Dependencies and base images:** Dependabot opens weekly PRs. Merge them once CI
  (including Trivy) passes.
- **ECR:** lifecycle policy keeps the last 30 images and expires untagged ones.
- **Logs:** retention is 14 days (`log_retention_days`).
- **Scaling:** change `desired_count` / `max_count` in tfvars; the backend scales on CPU (target 60%).
- **Terraform state:** S3 bucket `<project>-tfstate-<account-id>`, versioned and encrypted,
  with native S3 locking. Restore a previous version from the bucket if a state file is damaged.
- **Alerts:** confirm the SNS email subscription after the first apply, otherwise no emails arrive.
- **Teardown:** set `DEPLOY_ENABLED` to `false`; run Infrastructure → `destroy` for prod,
  dev, then shared; then delete the `ecslab-bootstrap` CloudFormation stack (in that order).
