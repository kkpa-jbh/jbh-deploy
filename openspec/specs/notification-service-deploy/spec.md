# notification-service-deploy Specification

## Purpose
TBD - created by archiving change deploy-add-notification-service. Update Purpose after archive.
## Requirements
### Requirement: Production compose runs jbh-notification
`compose.yaml` SHALL define service `jbh-notification` with image `ghcr.io/kkpa-jbh/jbh-notification:${JBH_NOTIFICATION_TAG}`,
no `ports`, no `expose`, only the network `jbh-private`, memory limit `${NOTIFICATION_MEM_LIMIT:-384M}`,
`JAVA_OPTS` `-Xmx${NOTIFICATION_XMX:-192m}`, a CPU limit, `cap_drop: ALL`, `no-new-privileges:true`, a read-only root file system,
and a healthcheck on `http://localhost:7778/q/health`.

#### Scenario: Service is private and limited
- **WHEN** `docker compose --env-file .env.example -f compose.yaml config` renders `jbh-notification`
- **THEN** its networks are only `jbh-private`, it has no published or exposed port, its memory limit is 384M and `JAVA_OPTS` is `-Xmx192m`

#### Scenario: Tag is required
- **WHEN** `JBH_NOTIFICATION_TAG` is not set in the env file
- **THEN** `docker compose config` fails with `set JBH_NOTIFICATION_TAG in .env`

#### Scenario: Same database as before
- **WHEN** `jbh-notification` is rendered
- **THEN** `DATABASE_URL` is `jdbc:postgresql://jbh-postgres:5432/jbh_finance`, and `jbh-postgres` (healthy) and `jbh-consul` (started) are in `depends_on`

### Requirement: Email settings belong to jbh-notification only
`GMAIL_HOST`, `GMAIL_PORT`, `GMAIL_USERNAME`, `GMAIL_APP_PASSWORD`, `GMAIL_FROM` and `JBH_FRONTEND_URL` SHALL be set on
`jbh-notification` and SHALL NOT be set on `jbh-personal-finance`, in `compose.yaml` and in `compose.local.yaml`.
`jbh-iam` keeps its own use of `JBH_FRONTEND_URL` for `CORS_ALLOWED_ORIGINS`.

#### Scenario: Finance has no email settings
- **WHEN** `jbh-personal-finance` is rendered from either compose file
- **THEN** no environment key starts with `GMAIL_` and `JBH_FRONTEND_URL` is absent

#### Scenario: Missing Gmail variable stops only the notification service
- **WHEN** `GMAIL_USERNAME` is empty in the production env file
- **THEN** `docker compose config` fails with `set GMAIL_USERNAME in .env`, and the message belongs to `jbh-notification`

### Requirement: Local compose runs jbh-notification
`compose.local.yaml` SHALL define `jbh-notification` with image `ghcr.io/kkpa-jbh/jbh-notification:latest`, host port `7778:7778`,
`CONSUL_DISCOVERY_HOSTNAME` `host.docker.internal`, the same database as finance, and empty-default `GMAIL_*` values.

#### Scenario: Local file is valid
- **WHEN** `docker compose --env-file .env.local.example -f compose.local.yaml config -q` runs
- **THEN** it exits 0 and the rendered `jbh-notification` publishes port 7778

#### Scenario: Swap for the IDE
- **WHEN** a developer runs `make local-swap s=jbh-notification`
- **THEN** the container stops and the target prints, among others, `DATABASE_URL=jdbc:postgresql://localhost:5433/jbh_finance`, `DATABASE_USERNAME` and `DATABASE_PASSWORD=<from .env.local>`

### Requirement: jbh-notification is the fifth app service for deploys
`ci-deploy.sh` SHALL accept `jbh-notification` and map it to `JBH_NOTIFICATION_TAG`. The service list in `ci-deploy.sh` and the `options` list in
`.github/workflows/deploy.yml` SHALL contain the same five names: `jbh-web`, `jbh-gateway`, `jbh-iam`, `jbh-personal-finance`, `jbh-notification`.
Neither list SHALL contain `jbh-postgres` or `jbh-consul`.

#### Scenario: Notification deploy is accepted
- **WHEN** `ci-deploy.sh` gets `deploy jbh-notification` or `rollback jbh-notification`
- **THEN** it does not refuse and uses `JBH_NOTIFICATION_TAG`

#### Scenario: Infrastructure services stay refused
- **WHEN** `ci-deploy.sh` gets `deploy jbh-postgres` or `deploy jbh-consul`
- **THEN** it prints `Refused` and exits 2

### Requirement: Env examples declare the new variables
`.env.example` SHALL contain `JBH_NOTIFICATION_TAG=latest`, `NOTIFICATION_CPU_LIMIT=0.5`, `NOTIFICATION_MEM_LIMIT=384M`,
`NOTIFICATION_XMX=192m`, and the Gmail block under a `jbh-notification` comment. `.env.local.example` SHALL label its Gmail block `jbh-notification`.

#### Scenario: Example env renders
- **WHEN** compose is rendered with `.env.example`
- **THEN** `GMAIL_USERNAME` of `jbh-notification` is `change-me@gmail.com`

### Requirement: AWS stack sends no email
`aws/finance-fargate.yaml` SHALL NOT define `GMAIL_*`, `JBH_FRONTEND_URL` or parameter `FrontendUrl`.
`aws/README.md` SHALL NOT list `GMAIL_*` in the secret JSON, and SHALL say in one line that the stack sends no email.

#### Scenario: No email settings on AWS
- **WHEN** `grep -rn GMAIL aws/` runs
- **THEN** there is no match

### Requirement: Caddy and database files stay unchanged
`jbh.caddy` and `initdb/` SHALL NOT change. The `respond 404` block on `/jbh-api/notifications*` stays.

#### Scenario: No diff
- **WHEN** `git diff --stat -- jbh.caddy initdb` runs after the change
- **THEN** the output is empty

