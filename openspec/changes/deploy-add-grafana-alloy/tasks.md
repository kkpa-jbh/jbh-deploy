## Test blueprint

No unit tests and no integration tests in this change (config and docs only; the JBH-55 plan excludes them). No blueprint group.
Verification is the static checks in design.md "Test contract" (V1, V2, V9-V14, V17; optional V16). Nobody runs Alloy in this pipeline.
Scope: local only (2026-11-15). Everything for production is in JBH-84 (design.md, "Moved to JBH-84").

## 1. Alloy modules (observability/alloy/modules/)

Depends on: nothing. Three disjoint files; they can be written in parallel. Each file starts with a header comment (what it does, who imports it, which env vars it reads). Use the arguments, names and values from design.md D1, D5-D7.

- [x] 1.1 `modules/otlp.alloy`: `declare "otlp"` with arguments `environment` and `output`; `otelcol.receiver.otlp` (gRPC and HTTP) -> `otelcol.processor.memory_limiter` -> `otelcol.processor.transform` (resource context, three signals) -> `otelcol.processor.batch` -> `argument.output.value` (D5).
- [x] 1.2 `modules/jbh-scrape.alloy`: `declare "jbh_scrape"` with arguments `hosts` and `forward_to`; four `prometheus.scrape` (D6).
- [x] 1.3 `modules/postgres.alloy`: `declare "postgres"` with arguments `dsn` and `forward_to`; `prometheus.exporter.postgres` + `prometheus.scrape` (D7).

## 2. Entry file and headers (observability/alloy/)

Depends on: 1 (component and argument names).

- [x] 2.1 `local.alloy`: `import.file`, `otelcol.exporter.otlp "lgtm"`, `prometheus.remote_write "lgtm"`, `faro.receiver "app"` with `otelcol.receiver.loki`, `jbh.otlp` (`environment = "local"`), `jbh.jbh_scrape` (all hosts `host.docker.internal`), `jbh.postgres` (D3, D4, D11, D15). No host module.
- [ ] 2.3 Headers and comments, after the scope cut. `local.alloy` header must not list `jbh.host`. Module headers (`otlp`, `jbh-scrape`, `postgres`) must not say "imported by prod.alloy": say "local.alloy (a prod entry file can reuse it later, see JBH-84)", and in `jbh-scrape.alloy` fix the line about "local and prod" hosts the same way. Also fix any comment in `compose.local.yaml`, `.env.local.example` and `initdb/02-create-monitor-role.sh` that points to `DEPLOY.md` or to prod-only steps (the script says "see DEPLOY.md, Observability": point to `LOCAL.md` instead). Comments only, no logic change.

## 3. Monitor role script

Depends on: nothing.

- [x] 3.1 `initdb/02-create-monitor-role.sh`: `#!/bin/sh`, `set -eu`, header comment like `01-create-databases.sh`; `psql -v pw=...` with `:'pw'`; role, grant, extension in database `postgres` (design.md "Database").
- [ ] 3.2 `initdb/02-create-monitor-role.sh`: before the `psql` call, when `JBH_PG_MONITOR_PASSWORD` is empty or unset (`[ -z "${JBH_PG_MONITOR_PASSWORD:-}" ]`), print one line and `exit 0`. Reason: the prod `compose.yaml` mounts the same `initdb/` and does not pass this variable; with `set -u` a fresh prod volume would fail to initialise. The header comment says this (D7). Depends on: 3.1.

## 5. Local compose

Depends on: 1, 2, 3.

- [x] 5.1 `compose.local.yaml`: add `jbh-alloy` and volume `jbh-local-alloy-data` (D11); add the OTLP variables (`JBH_ENV: local`) to the four backends; add the Postgres `command` and `JBH_PG_MONITOR_PASSWORD`; update the header comment if it lists services.
- [ ] 5.2 `compose.local.yaml`: `JBH_PG_MONITOR_DSN` of `jbh-alloy` becomes `${JBH_PG_MONITOR_DSN:-postgresql://jbh_monitor:${JBH_PG_MONITOR_PASSWORD:?set JBH_PG_MONITOR_PASSWORD in .env.local}@jbh-postgres:5432/postgres?sslmode=disable}` (D7: default from the password, user override). Depends on: 5.1.

## 6. Env example

Depends on: 5 (variable names).

- [x] 6.2 `.env.local.example`: add `JBH_PG_MONITOR_PASSWORD` with a note (URL-safe, `openssl rand -hex 24`).
- [ ] 6.3 `.env.local.example`: add the optional override `# JBH_PG_MONITOR_DSN=` (commented out) with a note: the default is built from the password; set it to reach a Postgres on the Mac, example `postgresql://jbh_monitor:<password>@host.docker.internal:5432/postgres?sslmode=disable` (D7, D12). Depends on: 5.2.

## 7. Make targets

Depends on: 5. Same file for 7.2 and 7.3: do them in order.

- [x] 7.2 `local.mk`: `local-alloy`, `.PHONY`; keep `LOCAL_SWAPPABLE` unchanged (Alloy is not swapped).
- [ ] 7.3 `local.mk`: `local-alloy-logs` (`$(LOCAL_COMPOSE) logs -f --tail=200 jbh-alloy`) next to `local-alloy`, and add it to `.PHONY` (D13). Depends on: 7.2.

## 8. Docs

Depends on: 1-7 (names and values). Four disjoint files; parallel. Follow design.md D14 and the "System map sync" rule of `CLAUDE.md`. Do not touch `DEPLOY.md`.

- [ ] 8.1 `README.md`: local part only. A short "Observability (local)" paragraph (Alloy, local LGTM, dev OTLP port `14317`, link to `observability/README.md`). Do not change the "Production" section.
- [ ] 8.2 `LOCAL.md`: start the local LGTM then Alloy (`make local-up` or `make local-alloy`; `make local-alloy-logs`), ports table rows, how to see data in Grafana (`http://localhost:3000`), the "metrics stored twice" catch (ask the docker-lab owner to remove its two scrape jobs); and (a) the one-time SQL for an existing local volume plus a restart of `jbh-postgres`; (b) for a Postgres on the Mac (port 5432): `shared_preload_libraries = 'pg_stat_statements'` and `pg_stat_statements.track = top` in `postgresql.conf`, a restart, the same SQL, and `JBH_PG_MONITOR_DSN` to `host.docker.internal:5432`; (c) for a service run from the IDE: `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14317` and `OTEL_SDK_DISABLED=false` (IDE run config or the service's local profile).
- [ ] 8.4 `observability/README.md`: series budget table for the local scope (design.md; the prod budget is JBH-84's), "Where the metrics come from" (Alloy scrapes locally; gateway and Postgres rows), status note.
- [ ] 8.5 `CLAUDE.md`: files table rows for `observability/alloy/` (local) and `initdb/` (new script, with its skip guard). No change to the rules.

## 9. Static verification (leader runs)

Depends on: 1-8.

- [ ] 9.1 Run the `Complexity-Check` command from `CLAUDE.md` (both `docker compose ... config -q`), then V9-V14 and V17 from design.md. Check that `git diff --stat <base> -- compose.yaml .env.example Makefile DEPLOY.md ci-deploy.sh .github` is empty. Optional for the user: V16 (`alloy validate` of `local.alloy`).

Size estimate: 12 files, ~520 changed lines (tests and docs included)
