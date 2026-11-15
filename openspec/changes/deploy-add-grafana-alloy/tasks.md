## Test blueprint

No unit tests and no integration tests in this change (config and docs only; the JBH-55 plan excludes them). No blueprint group.
Verification is the static checks V1-V16 in design.md "Test contract". Nobody runs Alloy in this pipeline.

## 1. Alloy modules (observability/alloy/modules/)

Depends on: nothing. Four disjoint files; they can be written in parallel. Each file starts with a header comment (what it does, who imports it, which env vars it reads). Use the arguments, names and values from design.md D1, D5-D8.

- [ ] 1.1 `modules/otlp.alloy`: `declare "otlp"` with arguments `environment` and `output`; `otelcol.receiver.otlp` (gRPC and HTTP) -> `otelcol.processor.memory_limiter` -> `otelcol.processor.transform` (resource context, three signals) -> `otelcol.processor.batch` -> `argument.output.value` (D5).
- [ ] 1.2 `modules/jbh-scrape.alloy`: `declare "jbh_scrape"` with arguments `hosts` and `forward_to`; four `prometheus.scrape` (D6).
- [ ] 1.3 `modules/postgres.alloy`: `declare "postgres"` with arguments `dsn` and `forward_to`; `prometheus.exporter.postgres` + `prometheus.scrape` (D7).
- [ ] 1.4 `modules/host.alloy`: `declare "host"` with argument `forward_to`; `prometheus.exporter.unix` + `prometheus.scrape` (D8).

## 2. Entry files (observability/alloy/)

Depends on: 1 (component and argument names). Two disjoint files; parallel.

- [ ] 2.1 `local.alloy`: `import.file`, `otelcol.exporter.otlp "lgtm"`, `prometheus.remote_write "lgtm"`, `faro.receiver "app"` with `otelcol.receiver.loki`, `jbh.otlp` (`environment = "local"`), `jbh.jbh_scrape` (all hosts `host.docker.internal`), `jbh.postgres` (D3, D4, D11). No host module.
- [ ] 2.2 `prod.alloy`: `import.file`, `otelcol.auth.basic "cloud"` (`client_auth`), `otelcol.exporter.otlphttp "cloud"`, `prometheus.remote_write "cloud"`, `jbh.otlp` (`environment = "prod"`), `jbh.jbh_scrape` (service-name hosts), `jbh.postgres`, `jbh.host` (D3, D4, D8). No `faro.receiver`. All values from `sys.env`.

## 3. Monitor role script

Depends on: nothing.

- [ ] 3.1 `initdb/02-create-monitor-role.sh`: `#!/bin/sh`, `set -eu`, header comment like `01-create-databases.sh`; `psql -v pw=...` with `:'pw'`; role, grant, extension in database `postgres` (design.md "Database").

## 4. Production compose

Depends on: 1, 2, 3 (file names and variable names).

- [ ] 4.1 `compose.yaml`: add service `jbh-alloy` and volume `jbh-alloy-data` (D9); add the four OTLP variables to `jbh-iam`, `jbh-gateway`, `jbh-personal-finance`, `jbh-notification` (D10); add `command` with the two `pg_stat_statements` options and env `JBH_PG_MONITOR_PASSWORD` to `jbh-postgres`; update the header comment (memory sum 3520M, about 3.5 GB; new service in the file picture). No `ports:` anywhere.

## 5. Local compose

Depends on: 1, 2, 3. Disjoint from 4; parallel with it.

- [ ] 5.1 `compose.local.yaml`: add `jbh-alloy` and volume `jbh-local-alloy-data` (D11); add the OTLP variables (`JBH_ENV: local`) to the four backends; add the Postgres `command` and `JBH_PG_MONITOR_PASSWORD`; update the header comment if it lists services.

## 6. Env examples

Depends on: 4, 5 (variable names). Disjoint files; parallel.

- [ ] 6.1 `.env.example`: new "Observability" block with the placeholders of D12; change "total about 3.3 GB" to "about 3.5 GB"; add `ALLOY_CPU_LIMIT` and `ALLOY_MEM_LIMIT` to the limits block.
- [ ] 6.2 `.env.local.example`: add `JBH_PG_MONITOR_PASSWORD` with a note (URL-safe, `openssl rand -hex 24`).

## 7. Make targets

Depends on: 4, 5. Disjoint files; parallel.

- [ ] 7.1 `Makefile`: `alloy-logs`, `alloy-ui`, `.PHONY`, `help` lines (D13). Do not touch `deploy` / `rollback`.
- [ ] 7.2 `local.mk`: `local-alloy`, `.PHONY`; keep `LOCAL_SWAPPABLE` unchanged (Alloy is not swapped).

## 8. Docs

Depends on: 1-7 (names and values). Five disjoint files; parallel. Follow design.md D14 and the "System map sync" rule of `CLAUDE.md`.

- [ ] 8.1 `README.md`: Production picture and env table, OTLP variables, Postgres paragraph, memory note, "Observability" paragraph, dev OTLP port `14317`, link to `observability/README.md`.
- [ ] 8.2 `LOCAL.md`: start the local LGTM then Alloy, ports table rows, IDE OTLP value `http://localhost:14317`, how to see data in Grafana, the "metrics stored twice" catch (ask the docker-lab owner to remove its two scrape jobs).
- [ ] 8.3 `DEPLOY.md`: new section 8 "Observability (Grafana Alloy)" in this order: Grafana Cloud stack and token; `.env` values; one-time Postgres SQL, `make backup`, `make up` (planned restart); first start and checks (`make alloy-logs`, `make alloy-ui`, `SELECT count(*) FROM pg_stat_statements;`, Grafana Explore); the `DAC_READ_SEARCH` fallback; rows in "When something is wrong"; update section 7 memory and the first-deploy list; `.env` must be updated before the merge or the next deploy fails.
- [ ] 8.4 `observability/README.md`: series budget table (design.md), "Where the metrics come from" (Alloy scrapes in both places, gateway/Postgres/host rows), status note.
- [ ] 8.5 `CLAUDE.md`: files table rows for `observability/alloy/` and `initdb/` (new script). No change to the rules.

## 9. Static verification (leader runs)

Depends on: 1-8.

- [ ] 9.1 Run the `Complexity-Check` command from `CLAUDE.md` (both `docker compose ... config -q`), then V3-V15 from design.md. Optional for the user: V16 (`alloy validate`).

Size estimate: 18 files, ~800 changed lines (tests and docs included)
