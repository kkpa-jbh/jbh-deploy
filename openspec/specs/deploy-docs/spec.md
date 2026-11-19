# deploy-docs Specification

## Purpose
TBD - created by archiving change deploy-add-notification-service. Update Purpose after archive.
## Requirements
### Requirement: System map shows the new service
`README.md` SHALL list `jbh-notification` (port 7778, Consul name `jbh-notification`) and `jbh-commons-lib` in the projects table,
route `/jbh-api/notifications/**` to `jbh-notification` in the mermaid graph, the route table and the endpoint prefix table,
and `jbh-iam` → `jbh-notification` in the service-to-service table. It SHALL show `jbh-notification` in the databases, start order, env table and memory note.
It SHALL NOT list notifications under `jbh-personal-finance`, and SHALL NOT contain the "Build cycle" known gap.

#### Scenario: Route table is current
- **WHEN** a reader looks up `/jbh-api/notifications/**` in `README.md`
- **THEN** the target is `jbh-notification`, and the text says Caddy still answers `404` from the internet

#### Scenario: Build order has no cycle
- **WHEN** a reader looks at "Build dependencies between projects"
- **THEN** the order is `jbh-commons-lib` → `jbh-notification-contracts` (from `jbh-notification`) → `jbh-gateway-client` → services

### Requirement: CI.md matches the real workflows
`CI.md` SHALL NOT mention `publish-contracts` for `jbh-personal-finance`. It SHALL describe from the real workflow files:
`jbh-commons-lib` `CI` (`ci.yml`, `mvn -B verify` on pull requests into `main`) and `Publish` (`publish.yml`, on push to `main`);
`jbh-notification` `Image` (`image.yml`, image `ghcr.io/kkpa-jbh/jbh-notification`) and `Publish notification contracts` (`publish.yml`).
It SHALL list `jbh-notification` among the repos that need `PACKAGES_READ_TOKEN`, and give the publish order commons → contracts → client → services.

#### Scenario: Publish order is documented
- **WHEN** a reader looks at "Order for shared libraries"
- **THEN** the steps are `jbh-commons-lib` `Publish`, `jbh-notification` `Publish notification contracts`, `jbh-gateway-client` `Publish`, then the `Image` workflows

### Requirement: Local and deploy docs cover the new service
`LOCAL.md` SHALL list `jbh-notification` (port 7778) and `make local-swap s=jbh-notification`. `DEPLOY.md` SHALL list 5 app services and the
`jbh-notification` workflows, and SHALL hold the release order: deploy `jbh-notification` first and wait until it is healthy in Consul
(the gateway route answers `503` before that); then `jbh-gateway` and `jbh-personal-finance` in any order, because the gateway routes to one
service at a time and no email is sent twice; until finance is deployed without its notification module, do not change the `notifications` Liquibase changelog.
`aws/README.md` and `observability/README.md` SHALL match the code.

#### Scenario: Operator follows the release order
- **WHEN** an operator reads `DEPLOY.md` before the JBH-74 release
- **THEN** the first step is to set `JBH_NOTIFICATION_TAG` in `.env` and deploy `jbh-notification`, with the `503` and Liquibase warnings next to it

### Requirement: Docs describe the local Alloy setup
`README.md` SHALL have a short local "Observability" paragraph, name the dev OTLP port `14317`, and link to `observability/README.md`. It SHALL NOT change the "Production" section.
`LOCAL.md` SHALL explain how to start the local LGTM and then Alloy (`make local-up` or `make local-alloy`), list the published Alloy ports, say that the OTLP port on the Mac is `14317` (not the `4317` of the container) and that `make local-swap s=<service>` prints the endpoint and `OTEL_SDK_DISABLED=false` for a service run from the IDE, give the monitor SQL for an existing local volume, and the `postgresql.conf` lines and SQL for a Postgres installed on the Mac (port 5432).
`observability/README.md` SHALL hold the series budget table for the local scope and say that Alloy scrapes the metrics locally.
`CLAUDE.md` SHALL list `observability/alloy/` and the new `initdb/` script in its files table.

#### Scenario: Reader finds the OTLP endpoint for the IDE
- **WHEN** a reader looks in `LOCAL.md` for the endpoint of a service run from the IDE
- **THEN** it names port `14317` and tells the reader to run `make local-swap s=<service>`, which prints `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14317`

#### Scenario: Reader finds the series budget
- **WHEN** a reader opens `observability/README.md`
- **THEN** a table lists each local source with its estimated series and a total, and says the prod budget belongs to JBH-84

### Requirement: Docs describe make local-pg-monitor
`LOCAL.md` SHALL tell the user to run `make local-pg-monitor` for an existing local Postgres volume (with `PG_ADMIN_URL=postgresql://jbh_admin@localhost:5433/postgres`) and for the Postgres installed on the Mac (default URL),
SHALL say that a restart may be needed and that the target must then run again, and SHALL point to `initdb/sql/pg-monitor.sql` for what it runs. It SHALL NOT keep the hand-written monitor SQL or the `postgresql.conf` lines.
`CLAUDE.md` SHALL list `initdb/sql/pg-monitor.sql`, `local-pg-monitor.sh` and the `local-pg-monitor` target in its files table.
`compose.yaml`, `compose.local.yaml`, `.env.example`, `Makefile`, `DEPLOY.md`, `ci-deploy.sh`, `README.md` and `.github/` SHALL NOT change.

#### Scenario: Reader finds the one command
- **WHEN** a reader looks in `LOCAL.md` for how to prepare the Mac Postgres for Alloy
- **THEN** the text says `make local-pg-monitor`, the restart note and the second run, and no `CREATE ROLE` SQL block

#### Scenario: Production files are untouched
- **WHEN** `git diff --stat main -- compose.yaml compose.local.yaml .env.example DEPLOY.md Makefile ci-deploy.sh README.md .github` runs after the change
- **THEN** it prints nothing

### Requirement: Docs describe the IDE env file
`LOCAL.md` SHALL tell the reader to run `make local-ide-env` and give the IntelliJ steps: install the EnvFile plugin; Run, Edit Configurations, tab EnvFile, Enable, `+`, `.env file`,
the path of `jbh.env`; set the profile in the run configuration (IAM: `local`); run `make local-ide-env` again and restart after `compose.local.yaml` changes.
It SHALL say that `SPRING_PROFILES_ACTIVE` is not in the file, that newer IntelliJ versions may load an env file without the plugin, and that `make local-swap` still prints the masked values of one service.
It SHALL show `ln -s` for `jbh-personal-finance` and `jbh-notification` (Quarkus reads `.env`), with a warning to check that the repo's `.gitignore` covers `.env`, and SHALL say `jbh.env` holds real secrets.
`CLAUDE.md` SHALL list `jbh.env` and the `local-ide-env` target in its files table.
`compose.yaml`, `compose.local.yaml`, `.env.example`, `.env.local.example`, `Makefile`, `DEPLOY.md`, `README.md` and `.github/` SHALL NOT change.

#### Scenario: Reader sets up IntelliJ
- **WHEN** a reader looks in `LOCAL.md` for how to give a service its env vars in IntelliJ
- **THEN** the text says `make local-ide-env`, the EnvFile steps with the path of `jbh.env`, and that the profile is set in the run configuration

#### Scenario: Reader links a Quarkus repo
- **WHEN** a reader looks in `LOCAL.md` for the Quarkus `.env`
- **THEN** the text has the `ln -s` command and the `.gitignore` warning, and no make target for it

#### Scenario: Other files are untouched
- **WHEN** `git diff --stat main -- compose.yaml compose.local.yaml .env.example .env.local.example Makefile DEPLOY.md README.md .github` runs after the change
- **THEN** it prints nothing

### Requirement: Docs say that .env.local is the only source
`LOCAL.md` SHALL say that `make local-*` ignores the shell exports of the keys in `.env.local.example` and that the reader changes values in `.env.local`.
It SHALL warn that a `jbh-local-pgdata` volume keeps the Postgres user and password it was created with (Postgres sets them only at the first start),
so `.env.local` must match the volume, or the volume must be recreated. The text SHALL NOT tell the reader to run a command that deletes data without saying so.
`local-swap-env.sh` SHALL say in its header comment that a run through make ignores the shell exports and a run by hand reads them.
`Makefile`, `compose.yaml`, `compose.local.yaml`, `.env.example`, `.env.local.example`, `README.md`, `DEPLOY.md` and `.github/` SHALL NOT change.

#### Scenario: Reader wonders why a shell export has no effect
- **WHEN** a reader looks in `LOCAL.md` for the shell variable `POSTGRES_USER`
- **THEN** the text says the shell value is ignored by `make local-*` and `.env.local` is the source

#### Scenario: Reader changes the Postgres user on an old volume
- **WHEN** a reader looks in `LOCAL.md` for what happens when `POSTGRES_USER` differs from the volume
- **THEN** the text says the volume keeps its first user and names the two fixes (match `.env.local`, or recreate the volume and lose its data)

#### Scenario: Other files are untouched
- **WHEN** `git diff --stat main -- Makefile compose.yaml compose.local.yaml .env.example .env.local.example README.md DEPLOY.md .github` runs after the change
- **THEN** it prints nothing

