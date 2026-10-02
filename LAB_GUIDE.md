# Lab guide: secure CI/CD to AWS ECS Fargate with GitHub Actions

**100% in the browser.** You edit code in GitHub, Terraform and Docker run inside
GitHub Actions, and AWS is used through the AWS Console. There's nothing to install
on your computer.

At the end you will have a public GitHub repository with a working pipeline, real
deployments in your AWS account, and evidence (workflow runs, screenshots) to link
in your Upwork proposal.

| Job requirement | Where you practise it |
|---|---|
| GitHub OIDC, least-privilege IAM, role separation | Parts 2, 3, 5, 7 |
| Terraform (IaC), ECR, VPC, subnets, security groups, ALB, Route 53 | Parts 4–5 |
| ECS services, task definitions, Fargate | Part 5 |
| Secrets Manager, Parameter Store, env-specific configuration | Parts 5, 7 |
| GitHub Actions: tests, Docker builds, automated deploys to ECS | Part 6 |
| Environment workflows, approvals, protected environments | Parts 3, 6 |
| Health checks, rollback strategies | Parts 6–7 |
| Container, dependency and secret scanning (DevSecOps) | Parts 6–7 |
| Logging, monitoring, alerting | Part 8 |
| Documentation and troubleshooting | Part 9, `docs/RUNBOOK.md` |

### The tools you'll use (all in the browser)

| Tool | What for |
|---|---|
| **GitHub web editor** (press `.` on any repo page to open github.dev) | Edit files, create branches and pull requests |
| **GitHub Actions** | Runs tests, builds Docker images, runs Terraform, deploys |
| **AWS Console** | Look at everything that was created |
| **AWS CloudShell** (the `>_` icon in the AWS Console top bar) | A terminal inside AWS, with the AWS CLI already installed. Used once for the bootstrap, then optional. |
| **GitHub Codespaces** (optional) | A full editor with a terminal, in the browser. Only needed to upload the project in Part 1. |

**Time:** about 6–7 hours. **Cost:** roughly $3–5 per environment per day while it
runs (NAT gateway, load balancer, Fargate tasks), so around $10 for the day with dev
and prod. GitHub Actions minutes are free for public repositories.
**Destroy everything at the end (Part 10).**

### How it fits together

```
You (browser)
  │ edit code, open PRs, click "Run workflow", approve prod
  ▼
GitHub ──OIDC (short-lived credentials, no keys stored)──▶ AWS
  ├─ CI workflow          tests, builds, Trivy scans          (no AWS access)
  ├─ Infrastructure       terraform plan/apply/destroy        (role: <project>-gha-terraform)
  ├─ Deploy               build once → ECR → dev → approve → prod
  └─ Rollback             back to a previous task definition
```

---

## Part 0 — Accounts and safety (20 min)

1. **AWS account** with a user that has admin rights. **Never use the root user.**
2. **Region:** pick one and use it everywhere, e.g. **Europe (Paris) `eu-west-3`**
   (top-right of the AWS Console).
3. **Budget alert:** Billing and Cost Management → Budgets → Create budget → monthly
   cost budget, e.g. $20, email alert at 80%.
4. **GitHub account.**

Write down these two values, which you'll use throughout:

| Value | Example |
|---|---|
| Project name (2–12 lowercase characters) | `ecslab` |
| Repository | `<your-github-user>/ecs-fargate-cicd-lab` (case-sensitive!) |

---

## Part 1 — Put the project on GitHub (20 min)

1. On GitHub: **New repository** → name `ecs-fargate-cicd-lab` → **Public** (environment
   protection rules are free on public repos) → tick **Add a README file** → Create.
2. On the repository page: **Code → Codespaces → Create codespace on main**. A VS Code
   editor opens in the browser.
3. Drag `ecs-fargate-cicd-lab.zip` from your computer into the file explorer (left panel).
4. In the codespace terminal (bottom panel), run:
   ```bash
   unzip -q ecs-fargate-cicd-lab.zip
   cp -r ecs-fargate-cicd-lab/. .
   rm -rf ecs-fargate-cicd-lab ecs-fargate-cicd-lab.zip
   git add .
   git commit -m "ECS Fargate CI/CD lab"
   git push
   ```
5. Close the codespace (and delete it later under github.com/codespaces to save your
   free quota). From now on, you edit files in the browser editor.

Nothing deploys yet: the Deploy workflow stays off until you set `DEPLOY_ENABLED` in Part 6.

> **Without Codespaces:** unzip the file on your computer, then on GitHub use
> **Add file → Upload files** and drag in the *contents* of the folder. Check that the
> hidden `.github` folder was uploaded (on macOS, press Cmd+Shift+. in Finder to show it).

✅ **Checkpoint:** the repository shows `app/`, `infra/`, `bootstrap/`, `.github/workflows/`.

---

## Part 2 — One-time AWS bootstrap in CloudShell (15 min)

GitHub Actions needs a way into AWS before it can run Terraform. This one-time step
creates three things with CloudFormation:

- the **GitHub OIDC identity provider** (GitHub gets short-lived credentials, no stored keys)
- the **S3 bucket for Terraform state** (private, encrypted, versioned, HTTPS only)
- the **`<project>-gha-terraform` role**, which only jobs in the GitHub environment
  `infra` of your repository can assume

In the AWS Console, check the region, then open **CloudShell** (the `>_` icon in the
top bar). Run, replacing `<you>` with your GitHub user:

```bash
git clone https://github.com/<you>/ecs-fargate-cicd-lab.git
cd ecs-fargate-cicd-lab

aws cloudformation deploy \
  --stack-name ecslab-bootstrap \
  --template-file bootstrap/bootstrap.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ProjectName=ecslab GitHubRepo=<you>/ecs-fargate-cicd-lab

aws cloudformation describe-stacks --stack-name ecslab-bootstrap \
  --query "Stacks[0].Outputs" --output table
```

Keep the two outputs: **TerraformRoleArn** and **TerraformStateBucket**.

> If it fails because the OIDC provider already exists in your account, add
> `CreateOidcProvider=false` to `--parameter-overrides` and run it again.
>
> **Without CloudShell:** download `bootstrap/bootstrap.yml` from GitHub (Raw →
> Save as), then CloudFormation → Create stack → Upload a template file, fill in
> the parameters, and tick the IAM acknowledgement.

Open `bootstrap/bootstrap.yml` on GitHub and read the role's permissions. You should be
able to explain them:

- `PowerUserAccess` for the AWS services, but **no IAM** except roles named `<project>-*`
- the only managed policy it may attach is the ECS task execution policy
- an explicit **Deny** stops it from changing its own permissions

✅ **Checkpoint:** in IAM → Roles → `ecslab-gha-terraform` → Trust relationships, the
`sub` condition is `repo:<you>/ecs-fargate-cicd-lab:environment:infra`.

---

## Part 3 — Configure GitHub (15 min)

Go to the repository **Settings**.

### Repository variables

**Secrets and variables → Actions → Variables → New repository variable:**

| Name | Value |
|---|---|
| `AWS_REGION` | `eu-west-3` (your region) |
| `PROJECT` | `ecslab` |

These are **variables, not secrets**: nothing here is sensitive. There are no AWS
keys anywhere.

### Environments

**Environments → New environment**, three times:

| Environment | Deployment branches | Required reviewers | Variables |
|---|---|---|---|
| `infra` | Selected branches → `main` | Optional (add yourself for extra safety) | `AWS_TERRAFORM_ROLE_ARN` = TerraformRoleArn, `TF_STATE_BUCKET` = TerraformStateBucket |
| `dev` | Selected branches → `main` | No | added in Part 5 |
| `prod` | Selected branches → `main` | **Yes, add yourself** | added in Part 5 |

Environment names must match exactly: the AWS roles trust these names.

---

## Part 4 — Create the shared resources with Terraform (20 min)

**Actions → Infrastructure → Run workflow** → stack `shared`, action `plan` → Run.

When it finishes, open the run: the **summary** lists what Terraform will create (two ECR
repositories, a lifecycle policy for each, and the image-push role).

Run it again with action **`apply`**. This also starts a second job, **Push initial
images**, which builds both Docker images and pushes them with the tag `initial` (the
ECS services need an image to start).

From the run summary, copy **`ecr_push_role_arn`** into a new **repository** variable:

| Name | Value |
|---|---|
| `AWS_ECR_PUSH_ROLE_ARN` | `arn:aws:iam::...:role/ecslab-gha-ecr-push` |

Explore in the AWS Console:

- **ECR:** two repositories, with *tag immutability* and *scan on push* enabled. Open
  an `initial` image and look at its vulnerability scan.
- **IAM → Roles → `ecslab-gha-ecr-push`:** it trusts only `ref:refs/heads/main` of your
  repo, and can push only to these two repositories.

✅ **Checkpoint:** you can explain why no AWS access key will ever be stored in GitHub.

---

## Part 5 — Create the dev and prod environments (60 min)

**Actions → Infrastructure → Run workflow** → `dev` → `apply`. It takes about 5–8
minutes. When it's done, start `prod` → `apply`.

While they run, read the Terraform files in `infra/env/` on GitHub, in this order:
`network.tf` → `alb.tf` → `secrets.tf` → `iam.tf` → `ecs.tf` → `monitoring.tf`.

From each run summary, copy two outputs into that **environment's** variables
(Settings → Environments → `dev` or `prod` → Add variable):

| Name | Output |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | `github_deploy_role_arn` |
| `APP_URL` | `app_url` (no trailing slash) |

Open the dev `app_url` in your browser. You should see the environment, version
`initial`, the Parameter Store message, and "Secret loaded: Yes".

Explore in the AWS Console (this is what the client will ask about):

- **VPC → Subnets / Route tables:** tasks run in private subnets with no public IP. Only
  the load balancer is public; tasks go out through the NAT gateway.
- **EC2 → Security groups:** the task security group accepts traffic *only from the
  load balancer's security group*, and only sends HTTPS out.
- **EC2 → Load balancers → Listeners → Rules:** `/api/*` goes to the backend, everything
  else to the frontend.
- **EC2 → Target groups → Health checks:** `/api/health` and `/healthz`.
- **ECS → Clusters → `ecslab-dev` → Services → backend:** the *Deployments* tab shows
  the circuit breaker with rollback enabled. The *Tasks* tab shows private IPs only.
- **ECS → Task definitions → `ecslab-dev-backend`:** in the JSON, `secrets` contains ARNs,
  not values.
- **IAM → Roles → `ecslab-dev-gha-deploy`:** trusts only `environment:dev`; can update
  only the dev services and pass only the dev roles.
- **Secrets Manager / Systems Manager → Parameter Store:** one secret and one parameter
  per environment.

> **Optional HTTPS:** if you own a domain in Route 53, set `domain_name` and
> `hosted_zone_id` in `infra/env/dev.tfvars` (edit it on GitHub), commit, and run
> Infrastructure → dev → apply. Terraform creates an ACM certificate validated through
> DNS, an HTTPS listener (TLS 1.3 policy), an HTTP → HTTPS redirect and an alias record.

✅ **Checkpoint:** both environments respond in the browser.

---

## Part 6 — Turn on the pipeline (45 min)

Add the repository variable **`DEPLOY_ENABLED`** = `true`.

**Actions → Deploy → Run workflow** (branch `main`). Watch the run:

1. **CI**: backend tests, frontend build, Trivy scans (secrets, dependencies, IaC),
   `terraform validate`, Docker image builds and image scans.
2. **Build & push**: one image per app, tagged with the commit SHA, scanned again
   before it's pushed to ECR.
3. **Dev**: new task definition revision, rolling deployment, wait for stability, check
   that the new revision is really running, smoke test.
4. **Prod**: *Waiting for review*. Click **Review deployments → prod → Approve and deploy**.
5. **Prod** deploys the **same image** that was tested in dev.

Refresh the app: the version is now the commit SHA, in both environments.

Open the "Configure AWS credentials" step logs: the credentials came from OIDC and
expire when the job ends.

### Protect `main`

**Settings → Rules → Rulesets → New branch ruleset** → target `main` →
**Require a pull request before merging** (required approvals 0, since you work alone)
and **Require status checks to pass** (add the CI checks, e.g. `Test & build (backend)`,
`Scan repository`, `Build & scan image (backend)`, `Build & scan image (frontend)`).

### Make a change through a pull request

1. On the repository page, press **`.`** to open the browser editor.
2. Edit `app/frontend/src/App.jsx`, e.g. change the subtitle text.
3. In the **Source Control** panel, commit to a **new branch** and choose **Create Pull Request**.
4. On the PR page: only CI runs, with no AWS access. When it's green, **merge**.
5. The Deploy workflow starts on `main`: dev → your approval → prod.

✅ **Checkpoint:** two successful end-to-end deployments, each with a prod approval.

---

## Part 7 — Break it on purpose (75 min)

This is the part that turns "theory" into experience you can talk about.

### 7.1 Failed deployment → automatic rollback

Simulate a configuration error that the tests can't catch. In a new branch, edit
`app/backend/src/index.js` and add at the top:

```js
if (!process.env.FEATURE_FLAG_REQUIRED) {
  console.error(JSON.stringify({ level: 'error', msg: 'missing FEATURE_FLAG_REQUIRED' }));
  process.exit(1);
}
```

Open a PR and merge it. CI passes (the tests use `createApp` directly, not `index.js`),
the image is pushed, and the dev deployment starts. Watch:

- **ECS → service → Events / Deployments:** new tasks start, exit, restart… then
  *deployment failed* and *rolling back* to the previous revision. With one task, ECS
  needs about 3 failed starts before it gives up, so this takes 5–10 minutes.
- **GitHub:** the Dev job fails ("Verify the new revision is running", or a timeout),
  and **prod never runs**.
- **CloudWatch → Log groups → `/ecs/ecslab-dev/backend`:** the error message.
- **Email** (if `alert_email` is set in the tfvars and you confirmed the subscription):
  the failed-deployment alert.
- The app keeps serving the previous version the whole time: no downtime.

Revert it with another PR (on the merged PR page, GitHub offers a **Revert** button).

### 7.2 Manual rollback

**Actions → Rollback → Run workflow** → `dev`, `frontend`, revision empty. Check the
version, then redeploy with **Actions → Deploy → Run workflow**. Try a `prod` rollback
too: it waits for your approval.

### 7.3 Rotate a secret

1. **Secrets Manager → `ecslab-dev/backend/api-secret` → Retrieve secret value → Edit**,
   replace the value with a new long random string, save.
2. Containers read secrets only at start-up, so restart them: **ECS → `ecslab-dev` →
   Services → backend → Update service → tick Force new deployment → Update**.
3. When the deployment finishes, the app still shows "Secret loaded: Yes".

The secret never appeared in Git, the image, the workflow or the logs.

### 7.4 Security gate: vulnerable base image

In a new branch, edit `app/backend/Dockerfile` and change the **runtime** stage to an
old, unsupported Node.js image:

```dockerfile
FROM node:16-alpine AS runtime
```

Open a PR. The **Build & scan image (backend)** check fails and lists the HIGH/CRITICAL
CVEs. Close the PR without merging and delete the branch.

### 7.5 Security gate: leaked secret

In a new branch, add a file `config/test-key.txt` containing a fake private key:

```
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAuFakeKeyForTrivyLabOnlyDoNotUseAAAAAAAAAAAAAAAAAAAAAAAAAA
QmFzZTY0RmFrZURhdGFGb3JTZWNyZXRTY2FubmluZ0xhYkV4ZXJjaXNlT25seUFBQUFBQUFB
-----END RSA PRIVATE KEY-----
```

Open a PR. The **Scan repository** check fails on the secret. Close the PR and delete
the branch. (GitHub push protection may also block some secret types before they reach
CI: that's another layer working.)

### 7.6 Prove the OIDC role separation

Start a **Rollback** run on `prod` and **reject** it at the approval step. The job never
starts, so it never receives a token for the prod role. In IAM, compare the trust policies
of `ecslab-dev-gha-deploy` and `ecslab-prod-gha-deploy`: a token issued to the `dev`
environment can't assume the prod role.

✅ **Checkpoint:** you've seen an automatic rollback, a manual rollback, a secret rotation,
and both security gates fail as intended.

---

## Part 8 — Observability (30 min)

- **CloudWatch → Logs Insights** → log group `/ecs/ecslab-dev/backend`:
  ```
  fields @timestamp, method, path, status, duration_ms
  | filter msg = "request"
  | stats count() by status
  ```
- **CloudWatch → Alarms:** 5xx errors, unhealthy targets, backend CPU.
- **CloudWatch → Container Insights:** CPU, memory and task count per service.
- **VPC → Flow logs:** rejected connections in `/vpc/ecslab-dev/flow-logs`.
- **Optional, from CloudShell:** open a shell inside a running dev backend container
  (ECS Exec is enabled in dev):
  ```bash
  TASK=$(aws ecs list-tasks --cluster ecslab-dev --service-name backend --query 'taskArns[0]' --output text)
  aws ecs execute-command --cluster ecslab-dev --task $TASK --container backend --interactive --command "/bin/sh"
  ```

---

## Part 9 — Make it portfolio-ready (45 min)

1. Take screenshots, upload them to `docs/images/` (Add file → Upload files), and link
   them in the README:
   - a full Deploy run (CI → build → dev → approval → prod)
   - the prod approval screen
   - the ECS service events with the automatic rollback from 7.1
   - the failed security checks from 7.4 and 7.5
   - the app in the browser showing the commit SHA
   - the IAM trust policy of the prod deploy role
2. Read `README.md` and `docs/RUNBOOK.md` again and adjust anything you did differently.
3. Add 3–4 lines to the README on what you'd do next (WAF, CloudFront, blue/green with
   CodeDeploy, Terraform plan on pull requests).
4. Pin third-party actions to commit SHAs (look up each release's SHA on GitHub). This
   protects against compromised tags, as happened with `tj-actions/changed-files` in
   March 2025, and clients reviewing your repo will notice it.

---

## Part 10 — Tear down (20 min) ⚠️

Don't skip this: NAT gateways and load balancers cost money every hour. **Follow this
order**, because the Terraform role must still exist to delete everything else.

1. Set the repository variable `DEPLOY_ENABLED` to `false`.
2. **Actions → Infrastructure → Run workflow**: `prod` → `destroy`, then `dev` →
   `destroy`, then `shared` → `destroy`.
3. **CloudFormation → Stacks → `ecslab-bootstrap` → Delete.** This removes the OIDC
   provider and the Terraform role. The state bucket is kept on purpose.
4. To remove the state bucket too: **S3 → `ecslab-tfstate-<account-id>` → Empty**, then **Delete**.
5. Check **Billing → Bills** the next day to confirm nothing is still running.

To show the project to a client later, rerun Parts 2, 4 and 5 (about 30 minutes).

---

## After the lab: answering the client's 7 questions

Be honest: describe this as a reference implementation you built, and connect it to your
production experience (Oracle operations, Intelcia AWS projects).

1. **ECS/Fargate:** Fargate services in private subnets behind an ALB with path-based
   routing, health checks, rolling deployments at 100% minimum capacity, circuit breaker
   with automatic rollback, CPU autoscaling. Link the repo.
2. **GitHub Actions:** PR pipeline (tests, builds, Trivy, Terraform checks); main pipeline
   that builds once, scans, pushes to ECR, deploys dev, waits for approval and promotes the
   same image to prod; Terraform run from Actions; a rollback workflow.
3. **AWS authentication:** GitHub OIDC, no stored keys. One role per purpose: a Terraform
   role trusted only from the `infra` environment, an image-push role trusted only from
   `main`, and one deploy role per environment trusted only from that GitHub environment.
   Least-privilege policies scoped to specific ECR repos, ECS services and `iam:PassRole`
   targets.
4. **Secrets:** Secrets Manager for sensitive values, Parameter Store for configuration,
   injected by ECS at start-up through the execution role (scoped to that environment's
   ARNs). Nothing in code, images, workflows or logs; GitHub holds only non-sensitive
   variables. Secret and dependency scanning in CI.
5. **Relevant experience:** this Node.js/React stack on ECS, plus your production AWS work
   (VPC, Transit Gateway, IAM, CloudWatch) and incident/RCA experience.
6. **Portfolio:** the GitHub repo, README architecture diagrams, screenshots.
7. **Timeline:** a realistic estimate for their app is 2–3 weeks (review of the existing
   setup, infrastructure, pipeline, security hardening, documentation), plus your weekly
   availability.
