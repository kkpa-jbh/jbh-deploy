## Why

JBH-55 wants one trace per request, metrics, logs and alerts for all JBH services, locally and in production.
This repo (`jbh-deploy`) has no collector today. Nothing scrapes the production metric endpoints, and the services have no
place to send OTLP traces and logs.
This change is section 1 of the JBH-55 plan (sub-issue JBH-56, parent JBH-55). Sections 2-6 (other repos) read the env var names
set here, so they are fixed: `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SDK_DISABLED`, `OTEL_TRACES_SAMPLER_ARG`, `JBH_ENV`.

## What Changes

- New folder `observability/alloy/`: shared custom components in `modules/` (`otlp.alloy`, `jbh-scrape.alloy`, `postgres.alloy`,
  `host.alloy`) and two entry files: `local.alloy` (sends to the local LGTM, has `faro.receiver`) and `prod.alloy`
  (sends to Grafana Cloud, has the host module, no `faro.receiver`).
- `compose.yaml`: new service `jbh-alloy` (pinned `grafana/alloy`, no `ports`, `jbh-private` only, 256M, no Docker socket,
  read-only host mounts for VPS metrics, a volume for the WAL). The four backends get the four `OTEL_*` / `JBH_ENV` variables.
  `jbh-postgres` gets `pg_stat_statements` start options and the monitor password.
- `compose.local.yaml`: the same `jbh-alloy` with `local.alloy`, ports published on `127.0.0.1` only
  (`14317`, `14318`, `12347`, `12345`). The Docker backends get the OTLP variables. `jbh-postgres` gets the same start options.
- `initdb/02-create-monitor-role.sh`: role `jbh_monitor`, `GRANT pg_monitor`, extension `pg_stat_statements` in database `postgres`.
- `.env.example`, `.env.local.example`: new placeholders (Grafana Cloud values, monitor password, Alloy memory, sampler ratio).
- `Makefile`, `local.mk`: `alloy-logs`, `alloy-ui`, `local-alloy`.
- Docs: `README.md` (system map), `LOCAL.md`, `DEPLOY.md` (Grafana Cloud setup, one-time Postgres SQL and restart on the VPS),
  `observability/README.md` (series budget, "Where the metrics come from"), `CLAUDE.md` (files table).
- **No change:** `ci-deploy.sh`, `.github/workflows/deploy.yml` (`jbh-alloy` is deployed with `make up`), `jbh.caddy`, `../kkpa-docker-lab`.

## Capabilities

### New Capabilities

- `alloy-deploy`: the Alloy configuration (modules, entry files), the `jbh-alloy` service in both compose files, the OTLP env
  variables on the backends, the env placeholders and the Make targets.
- `postgres-monitoring`: the `jbh_monitor` role, `pg_stat_statements` in `jbh-postgres`, the first-start script and the one-time
  step for the existing VPS database.

### Modified Capabilities

- `deploy-docs`: adds the requirement that the system map, local guide, deploy guide and observability guide describe Alloy.
  (Added as a new requirement. No existing requirement text changes.)

## Impact

- Files: `compose.yaml`, `compose.local.yaml`, `.env.example`, `.env.local.example`, `Makefile`, `local.mk`, `initdb/02-create-monitor-role.sh`,
  six files under `observability/alloy/`, `README.md`, `LOCAL.md`, `DEPLOY.md`, `observability/README.md`, `CLAUDE.md`.
- VPS memory: about 3.3 GB becomes about 3.5 GB for the jbh stack (adds 256M).
- The VPS `.env` needs the new variables before the next `make up` or `make deploy`: compose stops at once on a missing `:?` value.
- **Planned restart of `jbh-postgres`** on the VPS (all services lose the database for a few seconds). Do it at a quiet time. See design.md, "Database".
- Grafana Cloud free plan: 10,000 metric series for everything. Target in prod: at most 6,000 (design.md, "Series budget").
- Local: the `jbh-personal-finance` and `jbh-iam` jobs in `../kkpa-docker-lab/lgtm/prometheus.yaml` must be removed by the
  docker-lab owner, or local metrics are stored twice. This change does not edit that file.

## Non-goals

- No unit tests and no integration tests: this repo has config and docs only. No test blueprint.
- No Docker socket, no cAdvisor, no container log collection (logs go over OTLP).
- No `faro.receiver` in production (Faro goes straight to Grafana Cloud).
- No dashboards, no alert rules, no change in the services (sections 2-6 and 7+ of the plan).
- No change to `ci-deploy.sh`, `.github/workflows/deploy.yml`, `jbh.caddy` or `CI.md`.
- No edit of `../kkpa-docker-lab`.
