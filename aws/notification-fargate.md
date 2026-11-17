# jbh-notification on AWS Fargate

Status: **proposal**. Nothing here is deployed yet.

The task definition is `notification-taskdef.json`. This file explains what it needs, why each value
is set, and the commands to set it up. It assumes the whole JBH system moves to AWS, in one VPC.

## What the service does and needs

- Sends team invitation emails. Only `jbh-iam` calls it, through the gateway
  (`POST /jbh-api/notifications/v1?type=EMAIL`). Low traffic, idle most of the time.
- Each request: one DB write and one SMTP call to Gmail.
- Postgres: database `jbh_finance`, schema `notifications`. Liquibase migrates at start.
- The gateway finds it in **Consul** (`lb://jbh-notification`). No load balancer in front of it.
- Safe with 2 or more tasks: shared state lives in Postgres.

```
jbh-iam ─► jbh-gateway ─(Consul lookup)─► jbh-notification task :7778 ─► RDS :5432
                                                  │                  └─► smtp.gmail.com :465 (via NAT)
                                                  └─ registers in Consul :8500 at start, deregisters at stop
```

## Prerequisites

The task definition is one part of ten. Points 4 and 5 are the blockers: without them nobody can
call this service.

| # | Prerequisite | Exists today? |
|---|---|---|
| 1 | VPC, 2 private subnets in 2 AZs, NAT gateway (egress to GHCR and Gmail) | Only inside the finance stack |
| 2 | ECS cluster | Only inside the finance stack |
| 3 | RDS Postgres 16 with database `jbh_finance` (can be shared with finance) | Only inside the finance stack |
| 4 | **Consul on AWS**, reachable by a stable name (for example Cloud Map `jbh-consul.jbh.local`) | **No** |
| 5 | **jbh-gateway and jbh-iam on AWS**, using the same Consul | **No** |
| 6 | Secrets: GHCR pull, DB credentials, SMTP credentials | GHCR and DB only for finance |
| 7 | IAM: execution role (and an optional task role) | Only for finance |
| 8 | Security group `jbh-notification`, plus rules on the RDS and Consul groups | No |
| 9 | CloudWatch log group `/ecs/jbh-notification` | No |
| 10 | ECS service | No |

## Size

| Setting | Value | Why |
|---|---|---|
| `cpu` | `256` (0.25 vCPU) | Low traffic. CPU matters only at start (Hibernate + Liquibase). |
| `memory` | `512` MB | Fargate minimum for 0.25 vCPU. |
| `-Xmx` | `256m` | Half the memory, same ratio as the VPS (192m in 384 MB). The rest is metaspace, threads, buffers. |
| Tasks | 1 | Use 2 only if you need the service during an AZ failure. |

On the VPS it has 0.5 CPU, so the start is slower here. The health check gives it 120 s.
If the start takes longer, use `cpu 512` / `memory 1024` / `-Xmx512m`.

## Why each value in the task definition

| Value | Why |
|---|---|
| `db-init` container | Liquibase keeps its tables in schema `notifications`, so the schema must exist before the app starts. `IF NOT EXISTS` makes it safe on every start. The advisory lock stops 2 tasks from racing. |
| `dependsOn: SUCCESS` | The app starts only when `db-init` exited with `0`. |
| `DATABASE_URL` without query string | The app appends `?currentSchema=notifications`. A second `?` would break the URL. The driver default (`sslmode=prefer`) uses TLS with RDS. Strict `verify-full` would need a code change. |
| No `pgcrypto` | `gen_random_uuid()` is built into Postgres 13 and later. |
| `repositoryCredentials` | The image is on GHCR. Drop it, and the GHCR secret, if the package is public. |
| `readonlyRootFilesystem` + `tmp` volume | Same as the VPS (`read_only: true`). Fargate has no tmpfs, so an empty task volume gives a writable `/tmp`. |
| `capabilities.drop: ALL` | Same as the VPS (`cap_drop: ALL`). The VPS `no-new-privileges` has no Fargate field. |
| `CONSUL_PREFER_IP=true` | The app registers the task IP (the ENI IP on Fargate). The gateway and Consul reach it there. |
| Health check `/q/health/live` | The liveness check does not test the DB, so a short DB problem does not kill the task. Consul still checks `/q/health` (with the DB), so the gateway stops sending traffic to a task that cannot reach the DB. |
| `stopTimeout: 30` | ECS sends SIGTERM. The app deregisters from Consul, then exits. `exec java` in the Dockerfile keeps java as PID 1. |
| `-XX:+ExitOnOutOfMemoryError` | An out of memory error ends the task. ECS starts a new one. |
| `OTEL_SDK_DISABLED=true` | No OpenTelemetry collector on AWS yet. Set `false` and `OTEL_EXPORTER_OTLP_ENDPOINT` when one exists. |
| `awslogs` `mode: non-blocking` | A slow CloudWatch never blocks the app. Logs are JSON in the prod profile. |
| Image tag = git SHA | Never `latest`. A rollback is the previous task definition revision. |

### Environment variables

| Variable | Kind | Value |
|---|---|---|
| `DATABASE_URL` | plain | `jdbc:postgresql://<RDS_ENDPOINT>:5432/jbh_finance` |
| `DATABASE_USERNAME`, `DATABASE_PASSWORD` | secret | keys `username`, `password` of the RDS secret |
| `CONSUL_HOST`, `CONSUL_PORT` | plain | stable Consul name, `8500` |
| `CONSUL_PREFER_IP` | plain | `true` |
| `JBH_FRONTEND_URL` | plain | base URL for links in emails |
| `GMAIL_HOST`, `GMAIL_PORT`, `GMAIL_FROM` | plain | `smtp.gmail.com`, `465`, sender address |
| `GMAIL_USERNAME`, `GMAIL_APP_PASSWORD` | secret | keys of `jbh-notification/smtp` |
| `OTEL_SDK_DISABLED` | plain | `true` |
| `JAVA_OPTS` | plain | `-Xmx256m -XX:+ExitOnOutOfMemoryError` |

ECS reads each `secrets` entry when the task starts. The format `<secret-arn>:<json-key>::` picks one
key from a JSON secret. A missing key stops the task from starting.

## Set it up

Pick a region and keep it for every command. Example: `export AWS_REGION=us-east-1`.

### 1. Secrets

Reuse the GHCR secret and the RDS secret of the stack that owns the database. Create the SMTP secret
(a Gmail app password, not the account password):

```bash
aws secretsmanager create-secret \
  --name jbh-notification/smtp \
  --secret-string '{"GMAIL_USERNAME":"<gmail-user>","GMAIL_APP_PASSWORD":"<16-char app password>"}'
```

### 2. Log group

```bash
aws logs create-log-group --log-group-name /ecs/jbh-notification
aws logs put-retention-policy --log-group-name /ecs/jbh-notification --retention-in-days 14
```

The log group exists before the task, so the execution role needs no `logs:CreateLogGroup`.

### 3. Execution role

ECS uses this role to pull the image, read the secrets and write logs. The app does not use it.

`trust.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Principal": { "Service": "ecs-tasks.amazonaws.com" }, "Action": "sts:AssumeRole" }
  ]
}
```

`read-secrets.json` (only these 3 secrets):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": ["<GHCR_SECRET_ARN>", "<DB_SECRET_ARN>", "<SMTP_SECRET_ARN>"]
    }
  ]
}
```

```bash
aws iam create-role --role-name jbh-notification-execution --assume-role-policy-document file://trust.json
aws iam attach-role-policy --role-name jbh-notification-execution \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws iam put-role-policy --role-name jbh-notification-execution \
  --policy-name read-secrets --policy-document file://read-secrets.json
```

If a secret uses a customer-managed KMS key, add `kms:Decrypt` on that key.

### 4. Task role (optional)

The app calls no AWS API, so it needs no permission. Keep the role only for ECS Exec (a shell in the
running task, for debugging). Otherwise remove `taskRoleArn` from the task definition.

`ecs-exec.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ],
      "Resource": "*"
    }
  ]
}
```

```bash
aws iam create-role --role-name jbh-notification-task --assume-role-policy-document file://trust.json
aws iam put-role-policy --role-name jbh-notification-task --policy-name ecs-exec --policy-document file://ecs-exec.json
```

### 5. Security groups

| Group | Direction | Port | Peer | Why |
|---|---|---|---|---|
| `jbh-notification` | in | `7778` | gateway group | API traffic |
| `jbh-notification` | in | `7778` | Consul group | Consul health check |
| `jbh-notification` | out | `5432` | RDS group | database |
| `jbh-notification` | out | `8500` | Consul group | register and deregister |
| `jbh-notification` | out | `465`, `443` | `0.0.0.0/0` | Gmail SMTP, GHCR image pull (through the NAT) |
| RDS group | in | `5432` | `jbh-notification` | database |

```bash
SG=$(aws ec2 create-security-group --group-name jbh-notification \
  --description "jbh-notification tasks" --vpc-id <VPC_ID> --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 7778 --source-group <GATEWAY_SG>
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 7778 --source-group <CONSUL_SG>
aws ec2 authorize-security-group-ingress --group-id <RDS_SG> --protocol tcp --port 5432 --source-group "$SG"
```

A new group allows all outbound traffic. To keep only the 4 outbound rules above, revoke the default
rule and add them with `authorize-security-group-egress`.

### 6. Register the task definition

Copy `notification-taskdef.json`, replace every `<...>` placeholder, then:

```bash
aws ecs register-task-definition --cli-input-json file://notification-taskdef.json
```

Each run creates a new revision (`jbh-notification:1`, `:2`, ...).

### 7. Create the service

Private subnets, no public IP, no load balancer. The circuit breaker rolls back by itself when new
tasks keep failing. `100/200` starts the new task before the old one stops.

```bash
aws ecs create-service \
  --cluster <CLUSTER> \
  --service-name jbh-notification \
  --task-definition jbh-notification \
  --desired-count 1 \
  --launch-type FARGATE \
  --platform-version LATEST \
  --network-configuration "awsvpcConfiguration={subnets=[<PRIVATE_SUBNET_A>,<PRIVATE_SUBNET_B>],securityGroups=[$SG],assignPublicIp=DISABLED}" \
  --deployment-configuration "minimumHealthyPercent=100,maximumPercent=200,deploymentCircuitBreaker={enable=true,rollback=true}" \
  --enable-execute-command
```

Drop `--enable-execute-command` if you skipped the task role.

**Deploy a new version:** change the image tag, register again, then:

```bash
aws ecs update-service --cluster <CLUSTER> --service jbh-notification --task-definition jbh-notification
```

**Rollback:** `update-service` with the previous revision, for example `--task-definition jbh-notification:3`.

## Check it

```bash
# Logs of db-init and app
aws logs tail /ecs/jbh-notification --follow

# Running tasks and the last events
aws ecs describe-services --cluster <CLUSTER> --services jbh-notification \
  --query 'services[0].{running:runningCount,desired:desiredCount,events:events[:5].message}'

# Consul must list the task IP (not 127.0.0.1) as passing
curl -s "http://<CONSUL_HOST>:8500/v1/health/service/jbh-notification?passing" | jq '.[].Service.Address'
```

On the first deploy, also check in the logs:
- Quarkus starts with the read-only root and the `/tmp` volume.
- The start fits in 120 s at 0.25 vCPU.

End-to-end test: invite a user to a team in the app. `jbh-iam` calls this service and the email arrives.

## Cost (about, us-east-1, per month)

| Item | USD |
|---|---|
| 1 Fargate task (0.25 vCPU, 0.5 GB, always on) | 9 |
| Secrets Manager (1 new secret), CloudWatch logs | 1 |
| **Total for this service** | **~10** |

The NAT gateway, RDS and the cluster are shared with the other services, so they are not counted here.

## Limits

- **Block the path from the internet.** On the VPS, Caddy answers `404` for `/jbh-api/notifications/*`.
  On AWS, whatever is in front of the gateway (ALB or CloudFront) must do the same. Otherwise any
  logged-in user can send email (see "Known gaps" in `../README.md`).
- Consul and the gateway must run on AWS first. Until then this task starts but receives no traffic.
- One NAT gateway: if its AZ fails, no email goes out.
- Gmail limits how many emails an account sends per day. For more volume, use Amazon SES.
  Its SMTP interface needs no code change: only new `GMAIL_HOST`, `GMAIL_PORT` and SMTP credentials.
