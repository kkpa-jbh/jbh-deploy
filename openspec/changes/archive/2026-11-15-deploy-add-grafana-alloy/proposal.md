## Why

JBH-55 wants one trace per request, metrics, logs and alerts for all JBH services. The work is now local-first: build and test on a developer
machine with the local LGTM. Every production part moves to a separate prod ticket.
This repo (`jbh-deploy`) has no collector today. Nothing scrapes the metric endpoints locally, and the services have no
place to send OTLP traces and logs.
This change is section 1 of the JBH-55 plan (sub-issue JBH-56, parent JBH-55). Sections 2-6 (other repos) read the env var names
set here, so they are fixed: `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SDK_DISABLED`, `JBH_ENV`.

## What Changes

- New folder `observability/alloy/`: shared custom components in `modules/` (`otlp.alloy`, `jbh-scrape.alloy`, `postgres.alloy`) and one entry file,
  `local.alloy` (sends to the local LGTM, has `faro.receiver`). The modules take arguments, so a prod entry file can reuse them later.
- `compose.local.yaml`: new service `jbh-alloy` with `local.alloy`, ports published on `127.0.0.1` only (`14317`, `14318`, `12347`, `12345`).
  The Docker backends get the OTLP variables. `jbh-postgres` gets `pg_stat_statements` start options and the monitor password.
- `initdb/02-create-monitor-role.sh`: role `jbh_monitor`, `GRANT pg_monitor`, extension `pg_stat_statements` in database `postgres`.
  It skips itself when `JBH_PG_MONITOR_PASSWORD` is empty or unset (the prod compose file mounts the same folder and does not pass it).
- `.env.local.example`: new placeholder `JBH_PG_MONITOR_PASSWORD`, and an optional `JBH_PG_MONITOR_DSN` override (compose builds a default DSN from the password).
- `local.mk`: `local-alloy` and `local-alloy-logs`.
- Docs (local part only): `README.md` (system map), `LOCAL.md` (also: monitor SQL for an existing volume, Postgres on the Mac, IDE services), `observability/README.md` (series budget, "Where the metrics come from"),
  `CLAUDE.md` (files table).
- **No change:** `compose.yaml`, `.env.example`, `Makefile`, `DEPLOY.md`, `ci-deploy.sh`, `.github/workflows/deploy.yml`, `jbh.caddy`, `../kkpa-docker-lab`.

## Capabilities

### New Capabilities

- `alloy-deploy`: the Alloy configuration (modules, local entry file), the `jbh-alloy` service in `compose.local.yaml`, the OTLP env
  variables on the local Docker backends, the env placeholder and the `local-alloy` target.
- `postgres-monitoring`: the `jbh_monitor` role, `pg_stat_statements` in the local `jbh-postgres`, and the first-start script with its skip guard.

### Modified Capabilities

- `deploy-docs`: adds the requirement that the system map, local guide and observability guide describe the local Alloy setup.
  (Added as a new requirement. No existing requirement text changes.)

## Impact

- Files: `compose.local.yaml`, `.env.local.example`, `local.mk`, `initdb/02-create-monitor-role.sh`, five files under `observability/alloy/`,
  `README.md`, `LOCAL.md`, `observability/README.md`, `CLAUDE.md`.
- Production is not touched. The prod `compose.yaml` mounts `initdb/`, so a fresh prod volume runs the new script: the skip guard makes it a no-op there.
- Local: the `jbh-personal-finance` and `jbh-iam` jobs in `../kkpa-docker-lab/lgtm/prometheus.yaml` must be removed by the
  docker-lab owner, or local metrics are stored twice. This change does not edit that file.
- An existing local Postgres volume needs the monitor SQL by hand (documented in `LOCAL.md`) and a restart of `jbh-postgres`.

## Non-goals

- No unit tests and no integration tests: this repo has config and docs only. No test blueprint.
- No Docker socket, no cAdvisor, no container log collection (logs go over OTLP).
- No dashboards, no alert rules, no change in the services (other sections of the plan).
- Moved to JBH-84: `prod.alloy`, `modules/host.alloy` (VPS host metrics), `jbh-alloy` in `compose.yaml`, `OTEL_*` variables for prod services,
  the prod Postgres start options, Grafana Cloud variables in `.env.example`, `DEPLOY.md`, `Makefile` `alloy-logs` / `alloy-ui`, prod Faro, the prod series budget.
- No change to `ci-deploy.sh`, `.github/workflows/deploy.yml`, `jbh.caddy` or `CI.md`.
- No edit of `../kkpa-docker-lab`.
