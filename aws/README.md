# jbh-personal-finance on AWS Fargate

One CloudFormation template, `finance-fargate.yaml`. It runs `jbh-personal-finance` on ECS Fargate
behind an HTTPS load balancer, with its own RDS PostgreSQL database and CPU-based auto scaling.

## What the stack creates

```
Internet :443 → ALB (public subnets) → Fargate tasks :7777 (private subnets) → RDS :5432 (private subnets)
                                         └─ NAT gateway → internet (GHCR, VPS gateway, SMTP, AI APIs)
```

| Part | Resources |
|------|-----------|
| Network | VPC, 2 public + 2 private subnets in 2 AZs, internet gateway, 1 NAT gateway |
| Security groups | internet → ALB `443`/`80` · ALB → tasks `7777` · tasks → RDS `5432` |
| Load balancer | ALB, HTTP → HTTPS redirect, HTTPS listener with your ACM certificate |
| Database | RDS PostgreSQL 16 (`db.t4g.micro`), database `jbh_finance`, password in Secrets Manager |
| Compute | ECS cluster, task definition (0.5 vCPU, 1 GB), service with 3 tasks |
| Scaling | Min 3, max 6 tasks. Target tracking on average CPU 80% |
| Logs | CloudWatch log group `/ecs/<stack-name>`, 14 days |

### How a request flows

1. The ALB accepts only `/jbh-api/finance/*` and `/jbh-api/preferences/*`. Every other path answers `404`.
   `/jbh-api/notifications/*` answers `404` because finance has no notification endpoint any more.
   This stack sends no email: it runs no notification service.
2. A task handles the request. To know the user, it calls `jbh-iam` through the gateway on the VPS
   (`GatewayUrl`, default `https://jbh.usemagus.cloud`). A missing or bad token gets `401` there.
3. Consul is off (`CONSUL_ENABLED=false`). The ALB finds the tasks by IP.

### How a task starts

Each task has two containers:

1. `db-init` (`postgres:16-alpine`) creates the schemas `finance`, `preferences`, `notifications`, the
   `pgcrypto` extension, and the time zone. It uses `IF NOT EXISTS`, so it is safe on every start.
   An advisory lock stops 3 tasks from racing on `CREATE SCHEMA`.
2. `app` starts only when `db-init` exits with `0`. Liquibase then runs the migrations
   (it has its own lock, so only one task migrates).

The database starts empty. It is not a copy of the VPS data.

## Before you create the stack (once)

Pick a region and keep it for every command. Example: `export AWS_REGION=us-east-1`.

### 1. ACM certificate

Request a certificate for a subdomain you control, in the **same region** as the stack:

```bash
aws acm request-certificate \
  --domain-name jbh-aws.usemagus.cloud \
  --validation-method DNS
```

Read the validation `CNAME` record and add it at your DNS provider:

```bash
aws acm describe-certificate --certificate-arn <arn> \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord'
```

Wait until the status is `ISSUED`:

```bash
aws acm describe-certificate --certificate-arn <arn> --query 'Certificate.Status'
```

### 2. GHCR pull secret

Fargate pulls `ghcr.io/kkpa-jbh/jbh-personal-finance`. Create a GitHub classic token with only
`read:packages`, then:

```bash
aws secretsmanager create-secret \
  --name jbh-finance/ghcr \
  --secret-string '{"username":"<github-user>","password":"<read:packages token>"}'
```

### 3. App secret

Every key must exist, or the task does not start. For a feature you do not use, put a placeholder
such as `unused`. Without real AI keys the service still starts; only the bank statement import fails.

```bash
aws secretsmanager create-secret \
  --name jbh-finance/app \
  --secret-string '{
    "AZURE_DI_ENDPOINT": "unused",
    "AZURE_DI_API_KEY": "unused",
    "OPENROUTER_API_KEY": "unused",
    "GEMINI_API_KEY": "unused",
    "JEV_API_KEY": "unused"
  }'
```

Write down the two secret ARNs from the output.

### 4. Image tag

Use the git SHA of a `jbh-personal-finance` commit that the `image` workflow already pushed.
List the tags at https://github.com/orgs/kkpa-jbh/packages.

## Create or update the stack

The same command creates the stack the first time and updates it later.

```bash
aws cloudformation deploy \
  --stack-name jbh-finance \
  --template-file finance-fargate.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    ImageTag=<git-sha> \
    CertificateArn=<acm-certificate-arn> \
    GhcrCredentialsSecretArn=<jbh-finance/ghcr arn> \
    AppSecretArn=<jbh-finance/app arn>
```

The first run takes about 15 minutes (RDS and the NAT gateway are the slow parts).
Check the template before you deploy:

```bash
aws cloudformation validate-template --template-body file://finance-fargate.yaml
```

Other parameters have defaults (`DesiredCount=3`, `MaxCount=6`, `CpuTargetPercent=80`, `TaskCpu=512`,
`TaskMemory=1024`, `JavaHeap=512m`). Override them in `--parameter-overrides`.

**Deploy a new version:** run the same command with the new `ImageTag`. ECS starts new tasks, waits
until they are healthy, then stops the old ones. If the new tasks keep failing, the circuit breaker
rolls back by itself.

**Note:** an update of the stack sets the task count back to `DesiredCount`. Auto scaling then
adjusts it again.

## Point the subdomain to the load balancer

```bash
aws cloudformation describe-stacks --stack-name jbh-finance \
  --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerDnsName'].OutputValue" --output text
```

At your DNS provider, add a `CNAME` record: `jbh-aws` → that DNS name.

## Test it

Sign in on the VPS to get a token, then call the AWS stack with it:

```bash
TOKEN=$(curl -s https://jbh.usemagus.cloud/jbh-api/auth/signin \
  -H 'Content-Type: application/json' \
  -d '{"usernameOrEmail":"<user>","password":"<password>"}' | jq -r .accessToken)

curl -i https://jbh-aws.usemagus.cloud/jbh-api/preferences/v1 -H "Authorization: Bearer $TOKEN"
```

- `200` or `404` with a JSON body: the service works. The AWS database is empty, so a user has no
  preferences yet.
- `401`: the token is missing or expired (15 minutes).
- `503`: no healthy task. Read the logs.

## Watch it

```bash
# Logs of all tasks (app and db-init)
aws logs tail /ecs/jbh-finance --follow

# Running tasks and events
aws ecs describe-services --cluster <ClusterName output> --services <ServiceName output> \
  --query 'services[0].{running:runningCount,desired:desiredCount,events:events[:5].message}'

# Scaling activity
aws application-autoscaling describe-scaling-activities --service-namespace ecs
```

### See auto scaling work

Send load for a few minutes, for example with `hey` (`brew install hey`):

```bash
hey -z 5m -c 50 -H "Authorization: Bearer $TOKEN" https://jbh-aws.usemagus.cloud/jbh-api/preferences/v1
```

When the average CPU stays above 80%, a CloudWatch alarm fires and ECS adds tasks (up to 6).
After the load stops, it removes them slowly, back to 3. Each request also calls the VPS gateway,
so the VPS sees the same load. Keep tests short.

## Delete it

```bash
aws cloudformation delete-stack --stack-name jbh-finance
aws cloudformation wait stack-delete-complete --stack-name jbh-finance
```

The stack keeps a final RDS snapshot. Delete it and the two secrets by hand:

```bash
aws rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier'
aws rds delete-db-snapshot --db-snapshot-identifier <id>
aws secretsmanager delete-secret --secret-id jbh-finance/ghcr --force-delete-without-recovery
aws secretsmanager delete-secret --secret-id jbh-finance/app --force-delete-without-recovery
```

Also remove the `CNAME` records (subdomain and ACM validation) and the certificate if you do not need it.

## Cost (about, us-east-1, per month)

| Item | USD |
|------|-----|
| 3 Fargate tasks (0.5 vCPU, 1 GB, always on) | 54 |
| NAT gateway (plus data) | 33 |
| Application Load Balancer | 18 |
| RDS `db.t4g.micro` + 20 GB gp3 | 15 |
| Secrets Manager (3 secrets), CloudWatch logs | 2 |
| **Total** | **~120** |

The stack costs money every hour it exists, even with no traffic. Extra tasks from auto scaling cost
about 0.025 USD per task per hour.

## Limits

- One NAT gateway: if its AZ fails, tasks lose internet access (GHCR, VPS gateway, SMTP).
- RDS is single-AZ, with 1 day of backups.
- The tasks depend on the VPS gateway and `jbh-iam`. If the VPS is down, every request fails.
- The gateway's rate limit and JWT filter do not run here. Only the `findUserId` call checks the token.
