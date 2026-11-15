## Context

JBH-55 section 1, local-first (user decision 2026-11-15). Alloy is the single collector. Backends push OTLP (traces, logs) to it. Alloy scrapes the Prometheus endpoints of the
four backends and reads Postgres, then sends everything to the local LGTM. Every production part moved to JBH-84; its design notes are kept in "Moved to JBH-84 (kept for reuse)" below.
Decisions already made by the user (Step 2, binding): Alloy runs locally now (and in prod later, JBH-84); layout = shared `modules/` + `local.alloy` (+ `prod.alloy` in JBH-84); logs over OTLP, no Docker socket;
JVM metrics only (no cAdvisor); Postgres = basic metrics + `pg_stat_statements`; local `faro.receiver` on `12347`.

Verified facts:

- Local LGTM (`../kkpa-docker-lab/lgtm`): image `grafana/otel-lgtm:0.12.0`, host ports `3000`, `4317`, `4318`, `9090`. Only these four are published:
  Loki (`3100`) is not reachable from the host. Its Prometheus config scrapes `jbh-personal-finance` and `jbh-iam` itself.
- Backend metric endpoints: `jbh-iam:9999/actuator/prometheus`, `jbh-gateway:8080/actuator/prometheus`, `jbh-personal-finance:7777/q/metrics`,
  `jbh-notification:7778/q/metrics`. Finance, notification and IAM already add a `service` tag (and `env`) to every metric.
- Local `jbh-postgres` is `postgres:16-alpine`, host port 5433. `initdb/` had one script (`01-create-databases.sh`). The prod `compose.yaml` mounts the same `initdb/` folder.
- `grafana/alloy` (Docker Hub, checked 2026-11-15): latest stable `v1.22.0` (pushed 2026-11-13). The image is Ubuntu 24.04 based,
  has no `curl` and no `wget`, runs as root by default, and ships user `alloy` (uid 473) that owns `/var/lib/alloy/data`.
- Library docs were checked with Context7 (`/websites/grafana_alloy`, `/grafana/docker-otel-lgtm`) on 2026-11-15. Where they differ from the plan, see "Deviations from the plan".

## Decisions

### D1. Layout: modules as custom components, one local entry file

`observability/alloy/modules/*.alloy` each hold one `declare` block (arguments in, no secret inside). `local.alloy` does
`import.file "jbh" { filename = "/etc/alloy/modules" }`. A directory import is one module namespace, so the components are used as `jbh.otlp`,
`jbh.jbh_scrape`, `jbh.postgres`. Only the entry file differs between environments: exporters, hosts, Faro.
Everything that changes between environments is an argument or `sys.env(...)`. No secret is in a file.
Every file starts with a header comment: what it does, who imports it, which env vars it reads. The files contain only `declare`, `import.file` and
components, so a prod entry file (JBH-84) and Helm values (`alloy.configMap.content`) can reuse them later.
Why custom components: one pipeline definition, tested locally, reused in prod. Rejected: `import.git` (needs network at start, no gain here).

### D2. Local `jbh-alloy`: image pin, user and healthcheck

Image `grafana/alloy:v1.22.0` (pinned, never `latest`). It is the newest stable tag on Docker Hub (2026-11-13). If it misbehaves, `v1.21.0` is the fallback tag (same config).
Command: `run --server.http.listen-addr=0.0.0.0:12345 --storage.path=/var/lib/alloy/data /etc/alloy/local.alloy`. Flags go before the config path.
`user: "473:473"`: the named volume is created from the image folder and is owned by uid 473 (mode 770).
The image has no `wget`, so the healthcheck uses bash and `/dev/tcp` (bash, `head` and `grep` exist in Ubuntu):

```yaml
healthcheck:
  test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/12345 && printf 'GET /-/ready HTTP/1.0\\r\\n\\r\\n' >&3 && head -n 1 <&3 | grep -q ' 200 '"]
  interval: 15s
  timeout: 5s
  retries: 5
  start_period: 20s
```

`/-/ready` answers `200` with "Alloy is ready." once the config has loaded, `503` before.
The prod part of D2 (hardening, host mounts, `DAC_READ_SEARCH` fallback) is in "Moved to JBH-84".

### D3. Metrics path: `prometheus.remote_write`

Scraped metrics go to `prometheus.remote_write`, so metric names and labels stay exactly as today (the circuit breaker dashboard keeps working).
- Local: the `otel-lgtm` Prometheus accepts remote write. Verified in the image source (`grafana/docker-otel-lgtm`, tag `v0.12.0`, `docker/run-prometheus.sh`):
  it starts Prometheus with `--web.enable-remote-write-receiver` (and `--web.enable-otlp-receiver`). URL: `http://host.docker.internal:9090/api/v1/write`, no auth.
  Its `prometheus.yaml` is untouched, so no edit of `kkpa-docker-lab` is needed.
- Rejected: `otelcol.receiver.prometheus` -> OTLP. The OTLP path to Prometheus rewrites names (dots, unit suffixes, `_total`), which would break the dashboard and the PromQL names the services expect.
- Alloy WAL: `--storage.path` is a named volume (`jbh-local-alloy-data`), so queued samples survive a restart.
- The prod remote write (Grafana Cloud URL, basic auth) is in "Moved to JBH-84".

### D4. OTLP export: gRPC to the local LGTM

`otelcol.exporter.otlp "lgtm"` to `host.docker.internal:4317`, `tls { insecure = true }`, no auth. The exporter lives in the entry file (the environment-specific part).
The `jbh.otlp` module receives it as an `output` argument. The prod exporter is in "Moved to JBH-84".

### D5. `deployment.environment.name`: `otelcol.processor.transform`

The attribute is a resource attribute. `otelcol.processor.attributes` works on span, log and datapoint attributes, not on the resource. `otelcol.processor.transform` with `context = "resource"` is documented for it.
The module `jbh.otlp` sets it from its `environment` argument only when the service did not set it (`where attributes["deployment.environment.name"] == nil`).
The OTTL statement is a string, so the argument is joined with `+`. `error_mode = "ignore"`: a bad statement never drops data.
Pipeline order inside the module: `otelcol.receiver.otlp` (gRPC `0.0.0.0:4317`, HTTP `0.0.0.0:4318`) -> `otelcol.processor.memory_limiter` (`check_interval = "1s"`,
`limit_percentage = 75`, `spike_limit_percentage = 15`: percent of the container limit) -> `otelcol.processor.transform` -> `otelcol.processor.batch` (defaults) -> `output` argument.
Rejected: `otelcol.processor.resourcedetection` with the `env` detector (hides the value in a container env var instead of an argument).

### D6. Scrape module: one scrape component per backend

`jbh.jbh_scrape` has arguments `hosts` (object: service name -> host) and `forward_to`. It holds four `prometheus.scrape` components, one per backend, each with its own `job_name`
(the service name), `metrics_path`, `scrape_interval = "30s"`, `scrape_timeout = "10s"`, one target `<host>:<port>` and the target label `service = <name>`.
Ports and paths are fixed in the module (they belong to the services); only the hosts differ: local `host.docker.internal` for all four (prod would use the service names, JBH-84).
Why four components and not one with `__metrics_path__` labels: `job_name` is explicit, no doubt about the `job` label. Why not a loop: Alloy has none for components.
`honor_labels = true`: finance, notification and IAM already expose a `service` tag; with the default, Prometheus would rename it to `exported_service`. With `true` the exposed value wins and the target label fills the gap (the gateway has none).

### D7. Postgres module, monitor role skip guard

`jbh.postgres` (arguments `dsn`, `forward_to`): `prometheus.exporter.postgres` with `data_source_names = [argument.dsn.value]` and `enabled_collectors` = the Alloy defaults
(`database`, `locks`, `replication`, `replication_slot`, `roles`, `stat_bgwriter`, `stat_database`, `stat_progress_vacuum`, `stat_user_tables`, `statio_user_tables`, `wal`) plus `stat_statements`.
The docs list the defaults and say `enabled_collectors` "controls a subset"; they do not say that it adds to the defaults. So the list is explicit.
Then `prometheus.scrape` (`job_name = "jbh-postgres"`, `service = "jbh-postgres"`, 30s). The DSN: `postgresql://jbh_monitor:<password>@jbh-postgres:5432/postgres?sslmode=disable`.
The password must be URL-safe (`openssl rand -hex 24`), because it sits inside a URL.
The exporter connects only to database `postgres` (no `autodiscover_databases`), so the per-table collectors find no user tables and add almost no series.

**DSN in `compose.local.yaml` (exact interpolation).** The service `jbh-alloy` gets:

```yaml
JBH_PG_MONITOR_DSN: ${JBH_PG_MONITOR_DSN:-postgresql://jbh_monitor:${JBH_PG_MONITOR_PASSWORD:?set JBH_PG_MONITOR_PASSWORD in .env.local}@jbh-postgres:5432/postgres?sslmode=disable}
```

If `JBH_PG_MONITOR_DSN` is unset or empty in `.env.local`, the default is built from the password for the Docker `jbh-postgres`. A user can set it to reach another Postgres, for example one on the Mac:
`JBH_PG_MONITOR_DSN=postgresql://jbh_monitor:<password>@host.docker.internal:5432/postgres?sslmode=disable` (`<<: *app-host` already maps `host.docker.internal`).
`.env.local.example` lists the override commented out (`# JBH_PG_MONITOR_DSN=`), so the example file keeps the default. Compose supports nested `${...}` in a default value; the leader's static check (V2, V17) proves it.
Fallback if the nested form fails in the installed compose version: two variables `JBH_PG_MONITOR_HOST` (default `jbh-postgres`) and `JBH_PG_MONITOR_PORT` (default `5432`) inside a fixed DSN. Same task, no other file changes.

**Skip guard.** The prod `compose.yaml` mounts the same `initdb/` and does not pass `JBH_PG_MONITOR_PASSWORD`. With `set -u`, a fresh prod volume would fail to initialise.
So `02-create-monitor-role.sh` starts with: when `JBH_PG_MONITOR_PASSWORD` is empty or unset (`[ -z "${JBH_PG_MONITOR_PASSWORD:-}" ]`), print one line (`skip: JBH_PG_MONITOR_PASSWORD is not set`) and `exit 0`. The header comment says why. The guard comes before `psql`.

### D8. Host module (prod only)

Moved to JBH-84 (full text kept below).

### D9. `jbh-alloy` in `compose.yaml` (prod)

Moved to JBH-84 (full text kept below).

### D10. OTLP variables on the four backends (prod)

Moved to JBH-84 (full text kept below). The local variables are in D11.

### D11. Local compose and Faro

`jbh-alloy` in `compose.local.yaml`: same image and user, `<<: *app-host` (`host.docker.internal:host-gateway`), command with `/etc/alloy/local.alloy`, no hardening block (the local file has none for any service), but a memory limit of `256M` (the `memory_limiter` works in percent of it) and the D2 healthcheck on `/-/ready` (review round 1, R1 and R2),
no host mounts, no `depends_on`. Ports, all on `127.0.0.1` only: `127.0.0.1:14317:4317`, `127.0.0.1:14318:4318` (the local LGTM owns `4317`/`4318`), `127.0.0.1:12347:12347` (Faro), `127.0.0.1:12345:12345` (Alloy UI).
Env: `JBH_PG_MONITOR_DSN` (D7). A named volume `jbh-local-alloy-data`.
The Docker backends get `OTEL_EXPORTER_OTLP_ENDPOINT: http://jbh-alloy:4317`, `OTEL_SDK_DISABLED: "false"`, `JBH_ENV: local`. A service in the IDE sends to `http://localhost:14317` and sets `OTEL_SDK_DISABLED=false` (written in `LOCAL.md`).
`local.alloy`: targets on `host.docker.internal` (the same ports are published for Docker and IDE services); `faro.receiver "app"` with `listen_address = "0.0.0.0"` (inside the container; the host side is `127.0.0.1` only),
`listen_port = 12347`, `cors_allowed_origins = ["http://localhost:8100"]`.
Faro `output`: traces go to `otelcol.exporter.otlp.lgtm.input`. Logs go through `otelcol.receiver.loki` to the same OTLP exporter, because Loki's own port (`3100`) is not published by the local LGTM; the LGTM collector routes OTLP logs to Loki.

### D12. Env file (local)

`.env.local.example`: `JBH_PG_MONITOR_PASSWORD=change-me` (with the URL-safe note) and the optional override `# JBH_PG_MONITOR_DSN=` (commented, with the Mac example). Placeholders are non-empty so the static check passes.
The prod `.env.example` block is in "Moved to JBH-84".

### D13. Make targets (local)

`local.mk`: `local-alloy` (checks `.env.local`, then `$(LOCAL_COMPOSE) up -d jbh-alloy`; for IDE work) and `local-alloy-logs` (`$(LOCAL_COMPOSE) logs -f --tail=200 jbh-alloy`), both in `.PHONY`. `LOCAL_SWAPPABLE` stays unchanged.
`Makefile` is not touched (the `alloy-logs` / `alloy-ui` targets are in "Moved to JBH-84"). `ci-deploy.sh` and `deploy.yml` do not change.

### D14. Docs (local)

- `README.md`: a short "Observability (local)" paragraph (Alloy, local LGTM, dev OTLP port `14317`, link to `observability/README.md`). The "Production" section does not change.
- `LOCAL.md`: start the local LGTM (as `kkpa-docker-lab` documents), then `make local-up` (Alloy starts with it) or `make local-alloy`; ports table (`14317`, `14318`, `12347`, `12345`); where to see data in Grafana (`http://localhost:3000`, Explore); the "metrics stored twice" catch; and:
  (a) the one-time SQL for an existing local volume (`initdb/` does not run again), then a restart of `jbh-postgres`;
  (b) for a Postgres installed on the Mac (port 5432): `shared_preload_libraries = 'pg_stat_statements'` and `pg_stat_statements.track = top` in `postgresql.conf`, a restart, the same SQL, and `JBH_PG_MONITOR_DSN` pointing to `host.docker.internal:5432` (D7);
  (c) for a service run from the IDE: `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14317` and `OTEL_SDK_DISABLED=false` (IDE run config or the service's local profile).
- `observability/README.md`: series budget table (local scope); "Where the metrics come from" says Alloy scrapes locally; add the gateway and Postgres rows; fix the status note.
- `CLAUDE.md`: files table rows for `observability/alloy/` and the new `initdb/` script. The Rules section does not change.
- `DEPLOY.md` is not touched (JBH-84).

### D15. Faro receiver: `faro.receiver`

Docs checked with Context7 (`/websites/grafana_alloy`, "Choose a Grafana Alloy component", 2026-11-15): `otelcol.receiver.faro` (with `otelcol.exporter.faro`) is for Grafana Cloud Frontend Observability.
`faro.receiver` "is recommended only for a self-hosted Grafana setup". The local stack is a self-hosted LGTM, so `faro.receiver` is the right component. It sends logs to Loki receivers and traces to OTLP components, which fits D11.
`local.alloy` already uses `faro.receiver`: no task to switch it. For prod Faro (Grafana Cloud), JBH-84 decides again; the plan sends prod Faro straight to Grafana Cloud, so Alloy has no Faro receiver there.

## Deviations from the plan (docs win)

| Plan said | Docs say | Used |
|-----------|----------|------|
| Faro logs to Loki | Loki `3100` is not published by the local LGTM | `otelcol.receiver.loki` -> OTLP exporter |
| Attribute step (`attributes`/`resource`) | `otelcol.processor.attributes` is not for resource attributes; `otelcol.processor.resource` has no entry in the docs | `otelcol.processor.transform`, `context = "resource"` |
| `faro.receiver` default | `listen_address` default is `127.0.0.1` | `0.0.0.0` in the container, host side bound to `127.0.0.1` |
| `JBH_PG_MONITOR_DSN` listed in `.env.local.example` | the DSN can be built from the password | default built in compose, optional override listed (D7) |

## Test contract (expected values)

No unit tests and no integration tests: this repo holds config and docs only, and the JBH-55 plan excludes unit tests. **No test blueprint group.**
Verification is static. The leader runs V1-V14 and V17 with the build step; the user runs the optional checks.

| # | Check | Expected |
|---|-------|----------|
| V1 | `docker compose --env-file .env.example -f compose.yaml config -q` | exit 0, no output (`compose.yaml` is unchanged and still passes) |
| V2 | `docker compose --env-file .env.local.example -f compose.local.yaml config -q` | exit 0, no output |
| V9 | `config` of `compose.local.yaml`, service `jbh-alloy` | image `grafana/alloy:v1.22.0`; `user` `473:473`; exactly four published ports, each with `host_ip` `127.0.0.1`: `14317`->`4317`, `14318`->`4318`, `12347`->`12347`, `12345`->`12345`; command ends with `/etc/alloy/local.alloy`; healthcheck mentions `/-/ready`; no volume with source `/var/run/docker.sock` |
| V10 | same output, the four backends | `OTEL_EXPORTER_OTLP_ENDPOINT` = `http://jbh-alloy:4317`, `OTEL_SDK_DISABLED` = `false`, `JBH_ENV` = `local`; `jbh-postgres` command has `shared_preload_libraries=pg_stat_statements` and `pg_stat_statements.track=top`; env `JBH_PG_MONITOR_PASSWORD` = `change-me` |
| V11 | `head -n 15` of each of the four `.alloy` files | a header comment: what it does, who imports it, which env vars it reads; `local.alloy` header does not list `jbh.host`; no module header says "imported by prod.alloy" |
| V12 | `grep -rn "docker.sock" compose.yaml compose.local.yaml observability/` | no match (only prose in docs may say "no Docker socket") |
| V13 | `git diff --stat <base> -- compose.yaml .env.example Makefile DEPLOY.md ci-deploy.sh .github jbh.caddy` | empty |
| V14 | `sh -n initdb/02-create-monitor-role.sh`, then `grep -n 'JBH_PG_MONITOR_PASSWORD:-' initdb/02-create-monitor-role.sh` and `grep -n 'exit 0'` | syntax exit 0; the guard line and `exit 0` both appear on lines before the `psql` line. (Running the script needs `psql`, so it is not run.) |
| V16 (optional, user) | `docker run --rm -e JBH_PG_MONITOR_DSN=postgresql://u:p@h:5432/postgres -v "$PWD/observability/alloy:/etc/alloy:ro" grafana/alloy:v1.22.0 validate /etc/alloy/local.alloy` | exit 0 (`alloy validate` returns non-zero with diagnostics on stderr when the config is invalid). Also `alloy fmt` for formatting. Nothing in this pipeline runs Alloy. |
| V17 | `docker compose --env-file .env.local.example -f compose.local.yaml config`, then the same with `JBH_PG_MONITOR_DSN=postgresql://jbh_monitor:x@host.docker.internal:5432/postgres?sslmode=disable` in the environment | first: `jbh-alloy` has `JBH_PG_MONITOR_DSN` = `postgresql://jbh_monitor:change-me@jbh-postgres:5432/postgres?sslmode=disable`; second: the override value |

V3-V8 and V15 (prod `compose.yaml` and `prod.alloy` checks) moved to JBH-84; their text is kept in "Moved to JBH-84".

## Database

Planned database change (design gate `database`), **local Postgres only**. No table, column, index or Liquibase migration. The change is one role, one grant and one extension, plus a skip guard in the script.

**Objects**

| Object | Value |
|--------|-------|
| Role | `jbh_monitor`, `LOGIN`, password `JBH_PG_MONITOR_PASSWORD` (not superuser, no `CREATEDB`) |
| Grant | `GRANT pg_monitor TO jbh_monitor` (predefined role: includes `pg_read_all_stats`, `pg_read_all_settings`, `pg_stat_scan_tables`) |
| Extension | `CREATE EXTENSION IF NOT EXISTS pg_stat_statements` in database `postgres` |
| Server settings | `shared_preload_libraries=pg_stat_statements` and `pg_stat_statements.track=top`, as `-c` options of the `jbh-postgres` command in `compose.local.yaml` |

**First start (empty volume)** - `initdb/02-create-monitor-role.sh` (shell, so it reads the password from env; it runs after `01-create-databases.sh` by file name):

```sh
if [ -z "${JBH_PG_MONITOR_PASSWORD:-}" ]; then
  echo "02-create-monitor-role: JBH_PG_MONITOR_PASSWORD is not set, skipping"
  exit 0
fi
psql -v ON_ERROR_STOP=1 -v pw="$JBH_PG_MONITOR_PASSWORD" --username "$POSTGRES_USER" --dbname postgres <<'SQL'
CREATE ROLE jbh_monitor LOGIN PASSWORD :'pw';
GRANT pg_monitor TO jbh_monitor;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
```

`:'pw'` is psql's quoted-literal interpolation, so the password is escaped by psql and never concatenated into SQL. The guard exists because the prod `compose.yaml` mounts the same `initdb/` and does not pass the variable (D7).
Local `jbh-postgres` receives `JBH_PG_MONITOR_PASSWORD: ${JBH_PG_MONITOR_PASSWORD:?set JBH_PG_MONITOR_PASSWORD in .env.local}`.

**Existing local volume** - `initdb/` does not run on a non-empty volume, so `LOCAL.md` gives the same SQL to run by hand (`docker compose ... exec -T jbh-postgres psql -U "$POSTGRES_USER" -d postgres -v pw=...`) and a restart of `jbh-postgres` (`make local-up` recreates it, because its command changed). Local data only: no backup step.
The VPS one-time SQL and the planned restart are in "Moved to JBH-84".

**Why this design:**
- A dedicated least-privilege role: `pg_monitor` reads statistics only. Rejected: using `POSTGRES_USER` (admin) for the exporter: a leaked DSN would own all data.
- The extension is created once in database `postgres`: `pg_stat_statements` collects for the whole cluster, and the view in one database shows rows for all databases. Rejected: creating it in `jbh` and `jbh_finance` too (two more places, more exporter connections, same data).
- `pg_stat_statements.track=top` counts only top-level statements (not statements inside functions): fewer rows, less overhead. Rejected: `all`.
- The exporter connects to database `postgres` only. Rejected: `autodiscover_databases` (more series and connections for no gain).
- Not a Liquibase change: no JBH service owns this role. `initdb/` already holds the cluster-level setup (`pgcrypto`, time zone).
- `postgres:16-alpine` ships the `contrib` modules, so `pg_stat_statements` needs no new image.
- Skip guard instead of a prod-only copy of `initdb/`: one folder, one script, no prod file change in this ticket.

**Index plan: none needed.** No table is created or changed, so there is no index to add. The only reader is the exporter: every 30 seconds it reads the `pg_stat_statements` view (one cluster-wide scan of an in-memory hash table, 5000 entries at most by default, `pg_stat_statements.max`) and the `pg_stat_*` views. These are system views over shared memory, not heap tables with indexes. No read pattern of any JBH service touches them.

## Series budget (local scope; the prod budget is JBH-84's)

The free Grafana Cloud plan allows 10,000 series for everything, with a prod target of at most 6,000. That limit does not bind a laptop, but the same budget keeps the modules honest. The prod budget (it adds the VPS host rows) is JBH-84's.
Estimates from the typical size of each endpoint. The real counts are a user step (`curl -s <url> | grep -vc '^#'`); each service section of JBH-55 reports its own, and `observability/README.md` holds the table that the user updates.

| Source | Estimate | Note |
|--------|---------:|------|
| `jbh-iam` (Spring, Micrometer) | 1,000 | JVM, Tomcat/Hikari, HTTP histograms |
| `jbh-gateway` (Spring Cloud Gateway) | 700 | JVM, Netty, route and HTTP metrics |
| `jbh-personal-finance` (Quarkus) | 1,200 | JVM, Agroal, HTTP histograms (11 buckets) per endpoint |
| `jbh-notification` (Quarkus) | 600 | JVM, Agroal, few endpoints |
| Postgres, default collectors (database `postgres` only) | 350 | `stat_database` for 4 databases, `locks`, `wal`, `roles`, `stat_bgwriter` |
| Postgres `stat_statements` | 500 | about 100 statements x 5 counters (calls, rows, time, blocks read/written) |
| Alloy itself | 0 | `include_exporter_metrics` off, Alloy's own metrics are not scraped |
| **Total (local)** | **4,350** | headroom 1,650 below the 6,000 target. The VPS host module (about 250 series) is JBH-84's. |

Guard: if the real total passes 6,000, first lower the number of `pg_stat_statements` rows. Traces and logs have their own quotas and no series.

## Concurrency

Task numbers refer to `tasks.md`.

- **Tasks 5.1 and 8.2 (local metrics stored twice).** Risk: two writers for the same series: the local Prometheus scrape jobs of `kkpa-docker-lab` and Alloy's remote write. Proposed guard: ask the docker-lab owner to remove the `jbh-personal-finance` and `jbh-iam` jobs (report item, not a file edit).
- **Task 5.1 (Alloy WAL volume).** One container writes `jbh-local-alloy-data`. A second Alloy on the same volume would corrupt the WAL: compose runs one replica. No guard needed.
- **Task 3.2 (initdb script).** The script runs once, inside the Postgres entrypoint, before the server accepts connections: no concurrent writer. The skip guard is a pure check of one env variable. No guard needed.
- The Postgres restart for an existing local volume (task 8.2) is a single-developer action on local data. No guard needed. The VPS restart risk is JBH-84's.
- No shared memory, no async code, no handler that can run twice in this change. Alloy's own queues and retries are inside Alloy.

## Responsibilities

| File | One job | Who asks to change it |
|------|---------|-----------------------|
| `observability/alloy/modules/otlp.alloy` | Receive OTLP, limit memory, set the environment attribute, batch, forward | Whoever changes OTLP intake or sampling of resource data |
| `observability/alloy/modules/jbh-scrape.alloy` | Scrape the four backends (names, ports, paths, interval) | A service changes port or metrics path |
| `observability/alloy/modules/postgres.alloy` | Expose and scrape Postgres metrics | The Postgres metric set changes |
| `observability/alloy/local.alloy` | Local wiring: hosts, Faro, local exporters | The local LGTM or the local ports change |
| `initdb/02-create-monitor-role.sh` | Create the monitor role, grant and extension on a new volume; skip when no password is given | The monitoring user or extension changes |
| `compose.local.yaml` | Local service definitions; gains `jbh-alloy`, OTLP variables, Postgres options | Local topology changes |
| `.env.local.example` | Lists every local variable with a placeholder | A variable is added or renamed |
| `local.mk` | Laptop operator commands; gains `local-alloy`, `local-alloy-logs` | An operator task changes |
| `README.md` | System map; gains a local "Observability" paragraph | A route, port, env var or service changes |
| `LOCAL.md` | Laptop runbook | A step changes |
| `observability/README.md` | Observability guide and series budget | A signal or its source changes |
| `CLAUDE.md` | Repo files table and rules | A file is added |

`compose.yaml`, `.env.example`, `Makefile`, `DEPLOY.md` get no new job in this change. No file takes a second reason to change.

## Risks / Trade-offs

- `alloy validate` cannot prove the custom-component argument wiring for `otelcol` consumers (`argument "output"`). If it fails, the fallback is to export `input` from `jbh.otlp` and wire the exporter in the entry file; no other file changes.
- v1.22.0 is two days old. Fallback tag `v1.21.0`.
- The prod `compose.yaml` mounts `initdb/`: a fresh prod volume runs `02-create-monitor-role.sh`. The skip guard (D7, task 3.2) makes it a no-op. Without it, `set -u` would fail the first start.
- Nested interpolation in the DSN default (D7) depends on the compose version. The static check proves it; D7 names the fallback.
- A local Postgres volume created before this change has no monitor role: Alloy logs an authentication error for the Postgres scrape until the SQL in `LOCAL.md` is run. Other signals are not affected.
- `pg_stat_statements` query text may contain literal values. The exporter does not export query text by default (`include_query` off in the upstream exporter); only a hash id is a label. Keep it that way.

## Not included

- Dashboards and alert rules (later sections of JBH-55), changes in the services.
- Docker socket, cAdvisor, container log scraping, Alloy clustering.
- Edits to `ci-deploy.sh`, `.github/workflows/deploy.yml`, `jbh.caddy`, `CI.md`, `../kkpa-docker-lab`.
- Helm values (the files are written so they can move there later).
- Any test code (no unit tests, no integration tests).
- **Moved to JBH-84:** `prod.alloy`, `modules/host.alloy`, `jbh-alloy` in `compose.yaml`, `OTEL_*` / `JBH_ENV` for the prod services, the prod Postgres command and password, Grafana Cloud variables in `.env.example`, `DEPLOY.md`, `Makefile` `alloy-logs` / `alloy-ui`, prod Faro, the prod series budget. Notes below.

## Report item for the leader (not a file edit)

Tell the user: remove the `jbh-personal-finance` and `jbh-iam` jobs from `../kkpa-docker-lab/lgtm/prometheus.yaml`, or local metrics are stored twice.

## Moved to JBH-84 (kept for reuse)

These notes were written for this change before the scope cut (2026-11-15). Nothing here is built in JBH-56. JBH-84 reuses them from the archived change. The decision IDs are the ones above.
Differences from local: the entry file is `prod.alloy`; `jbh.host` is a fourth module (`modules/host.alloy`); the module files said "imported by local.alloy and prod.alloy".

### D1 (prod part). Entry file

`prod.alloy` does `import.file "jbh" { filename = "/etc/alloy/modules" }` and uses `jbh.otlp`, `jbh.jbh_scrape`, `jbh.postgres`, `jbh.host`. Exporters, hosts and the host module differ from `local.alloy`. No `faro.receiver`.

### D2 (prod part). Hardening and the capability fallback

Command: `run --server.http.listen-addr=0.0.0.0:12345 --storage.path=/var/lib/alloy/data /etc/alloy/prod.alloy`.
`user: "473:473"`: the named volume is created from the image folder, owned by uid 473 and mode 770. A root user with `cap_drop: ALL`
could not write there (no `DAC_OVERRIDE`). Host procfs, sysfs and root mounts are world-readable for the collectors we keep.
Fallback if a host collector gets "permission denied" on the VPS: keep `user` and add `cap_add: [DAC_READ_SEARCH]`. Check on first start (DEPLOY.md).

### D3 (prod part). Remote write

`GRAFANA_CLOUD_PROM_URL` (the remote-write URL from the Cloud portal) with `basic_auth` user `GRAFANA_CLOUD_PROM_USER` and password `GRAFANA_CLOUD_API_TOKEN`.

### D4 (prod part). OTLP export: HTTP to Grafana Cloud

Prod: `otelcol.exporter.otlphttp "cloud"` to `sys.env("GRAFANA_CLOUD_OTLP_ENDPOINT")` (the OTLP gateway, `https://otlp-gateway-<zone>.grafana.net/otlp`), with `otelcol.auth.basic`
(`client_auth` block: user `GRAFANA_CLOUD_INSTANCE_ID`, password `GRAFANA_CLOUD_API_TOKEN`). The gateway speaks OTLP over HTTP, so `otlphttp` and not `otlp`.
The exporters live in the entry file (they are the environment-specific part). The `jbh.otlp` module receives them as an `output` argument.
Docs deviation: top-level `username`/`password` of `otelcol.auth.basic` are deprecated; use a `client_auth` block. The Grafana Cloud OTLP gateway example uses `otelcol.exporter.otlphttp`.

### D6 (prod part). Scrape hosts

In prod the hosts are the Docker service names: `jbh-iam`, `jbh-gateway`, `jbh-personal-finance`, `jbh-notification`.

### D7 (prod part). Postgres DSN in prod

The DSN is built in `compose.yaml` from `JBH_PG_MONITOR_PASSWORD` and passed as env `JBH_PG_MONITOR_DSN`. The password must be URL-safe (`openssl rand -hex 24`).
`prod.alloy` and `local.alloy` read it from `sys.env("JBH_PG_MONITOR_DSN")`. `jbh-postgres` in prod needs the `command` with the two `-c` options (see Database below) and the env `JBH_PG_MONITOR_PASSWORD`.

### D8. Host module (prod only)

`jbh.host`: `prometheus.exporter.unix` with `procfs_path = "/host/proc"`, `sysfs_path = "/host/sys"`, `rootfs_path = "/host/root"`,
`set_collectors = ["cpu", "meminfo", "filesystem", "loadavg", "netdev"]` (everything else off, for the series budget), a `filesystem` block that excludes pseudo and Docker overlay mounts
(`mount_points_exclude = "^/(dev|proc|run/credentials/.+|sys|var/lib/docker/.+)($|/)"`), a `netdev` block that excludes `veth*`, `br-*`, `docker0`, `lo`.
Then `prometheus.scrape` (`job_name = "jbh-host"`, 30s). Mounts: `/proc` -> `/host/proc:ro`, `/sys` -> `/host/sys:ro`, `/` -> `/host/root` read-only with `bind.propagation: rslave`. No Docker socket, no `privileged`, no `pid: host`.

### D9. `jbh-alloy` in `compose.yaml` (prod)

Same hardening as the other services. Differences:

| Item | Value |
|------|-------|
| image / user | `grafana/alloy:v1.22.0`, `user: "473:473"` |
| command | `run --server.http.listen-addr=0.0.0.0:12345 --storage.path=/var/lib/alloy/data /etc/alloy/prod.alloy` |
| env | `GRAFANA_CLOUD_OTLP_ENDPOINT`, `GRAFANA_CLOUD_INSTANCE_ID`, `GRAFANA_CLOUD_API_TOKEN`, `GRAFANA_CLOUD_PROM_URL`, `GRAFANA_CLOUD_PROM_USER` (each `${VAR:?set VAR in .env}`), `JBH_PG_MONITOR_DSN: postgresql://jbh_monitor:${JBH_PG_MONITOR_PASSWORD:?...}@jbh-postgres:5432/postgres?sslmode=disable` |
| volumes | `./observability/alloy:/etc/alloy:ro`, `jbh-alloy-data:/var/lib/alloy/data`, `/proc:/host/proc:ro`, `/sys:/host/sys:ro`, `/` -> `/host/root` (read-only, `rslave`) |
| network | `jbh-private` only. No `ports`, no `expose`. Alloy needs outbound internet for Grafana Cloud (`jbh-private` is a plain bridge). |
| limits | `cpus: "${ALLOY_CPU_LIMIT:-0.25}"`, `memory: ${ALLOY_MEM_LIMIT:-256M}` |
| hardening | `restart: unless-stopped`, `logging: *default-logging`, `no-new-privileges:true`, `cap_drop: [ALL]`, `read_only: true`, `tmpfs: [/tmp]` |
| `depends_on` | none: a missing backend or database never stops the collector |

New named volume `jbh-alloy-data`. The header comment memory sum becomes 512+256+768+768+512+64+384+256 = 3520M, about 3.5 GB.
`ALLOY_CPU_LIMIT` is an addition to the plan (every other service has a CPU limit).

### D10. OTLP variables on the four backends (prod)

`jbh-iam`, `jbh-gateway`, `jbh-personal-finance`, `jbh-notification` get: `OTEL_EXPORTER_OTLP_ENDPOINT: http://jbh-alloy:4317`, `OTEL_SDK_DISABLED: "false"`,
`OTEL_TRACES_SAMPLER_ARG: ${OTEL_TRACES_SAMPLER_ARG:-1.0}`, `JBH_ENV: prod`. No `depends_on` on `jbh-alloy`: a missing collector never stops a service.
These names are fixed: sections 3-6 of the plan read them.

### D12 (prod part). `.env.example`

New block "Observability": `GRAFANA_CLOUD_OTLP_ENDPOINT=https://otlp-gateway-prod-change-me.grafana.net/otlp`, `GRAFANA_CLOUD_INSTANCE_ID=change-me`, `GRAFANA_CLOUD_API_TOKEN=change-me`,
`GRAFANA_CLOUD_PROM_URL=https://prometheus-prod-change-me.grafana.net/api/prom/push`, `GRAFANA_CLOUD_PROM_USER=change-me`, `JBH_PG_MONITOR_PASSWORD=change-me`, `ALLOY_CPU_LIMIT=0.25`, `ALLOY_MEM_LIMIT=256M`, `OTEL_TRACES_SAMPLER_ARG=1.0`.
The memory total in its limits comment becomes "about 3.5 GB". Placeholders are non-empty so the static check passes.

### D13 (prod part). Make targets and restart

`Makefile`: `alloy-logs` (`$(COMPOSE) logs -f --tail=200 jbh-alloy`), `alloy-ui` (prints the SSH tunnel command to the container IP and port `12345`, same pattern as `consul-tunnel`), both in `.PHONY` and `help`.
`ci-deploy.sh` and `deploy.yml` do not change: `jbh-alloy` is not one of the 5 app services and is deployed by `make up`. To restart it after a config change: `docker compose restart jbh-alloy` is enough (config is a bind mount), noted in DEPLOY.md.

### D14 (prod part). Docs

- `README.md`: Alloy in the "Production" picture and the env table (new row `jbh-alloy`, OTLP variables on the four backends, the `jbh-postgres` row), memory note 3.5 GB, Postgres paragraph (monitor role, `pg_stat_statements`), `ci-deploy.sh` still lists 5 services.
- `DEPLOY.md`: new section 8 "Observability (Grafana Alloy)": create the Grafana Cloud stack and an access policy token (scopes: `metrics:write`, `logs:write`, `traces:write`), where each value goes in `.env`, the one-time Postgres SQL and restart, first start, how to check that data arrives, rows in "When something is wrong". Update section 7 (memory) and the first-deploy list.

### Prod checks (V3-V8, V15)

| # | Check | Expected |
|---|-------|----------|
| V3 | `docker compose --env-file .env.example -f compose.yaml config --services` | 8 services, including `jbh-alloy` |
| V4 | `config` of `compose.yaml`, service `jbh-alloy` | image `grafana/alloy:v1.22.0`; networks only `jbh-private`; no `ports`, no `expose`; memory limit 268435456 (256M); `cap_drop` ALL; `read_only` true; `user` `473:473`; no volume whose source is `/var/run/docker.sock`; five volumes (config, data, `/proc`, `/sys`, `/`); healthcheck mentions `/-/ready` |
| V5 | same output, no service has `ports` | `grep -c "published:"` on the rendered output is 0 |
| V6 | same output, services `jbh-iam`, `jbh-gateway`, `jbh-personal-finance`, `jbh-notification` | each has `OTEL_EXPORTER_OTLP_ENDPOINT` = `http://jbh-alloy:4317`, `OTEL_SDK_DISABLED` = `false`, `OTEL_TRACES_SAMPLER_ARG` = `1.0`, `JBH_ENV` = `prod` |
| V7 | same output, service `jbh-postgres` | command has `shared_preload_libraries=pg_stat_statements` and `pg_stat_statements.track=top`; env `JBH_PG_MONITOR_PASSWORD` = `change-me` |
| V8 | `compose.yaml` with an env file that lacks `GRAFANA_CLOUD_API_TOKEN` | `config` fails with `set GRAFANA_CLOUD_API_TOKEN in .env` |
| V15 | `grep -n "sys.env" observability/alloy/prod.alloy` | five Grafana Cloud variables and `JBH_PG_MONITOR_DSN`; no literal token or password anywhere under `observability/alloy/` |
| V16 (prod) | `alloy validate` of `prod.alloy` with `-e GRAFANA_CLOUD_OTLP_ENDPOINT=https://x -e GRAFANA_CLOUD_INSTANCE_ID=1 -e GRAFANA_CLOUD_API_TOKEN=x -e GRAFANA_CLOUD_PROM_URL=https://x/api/prom/push -e GRAFANA_CLOUD_PROM_USER=1 -e JBH_PG_MONITOR_DSN=postgresql://u:p@h:5432/postgres` | exit 0 |

### Database (VPS part)

`jbh-postgres` in `compose.yaml` gets the same two `-c` options as the local file. `initdb/` does not run on a non-empty volume, so `DEPLOY.md` section 8 gets a one-time step, in this order:
1. Put the new variables in the VPS `.env` (all of them, before any `make` command).
2. Run the same SQL by hand against the running container (`docker compose --env-file .env -f compose.yaml exec -T jbh-postgres psql -U "$POSTGRES_USER" -d postgres -v pw=... `): `CREATE ROLE`, `GRANT pg_monitor`, `CREATE EXTENSION IF NOT EXISTS pg_stat_statements`. The extension and the role work before the restart; only the view needs the library.
3. `make up`: compose recreates `jbh-postgres` because its command changed. **This is the planned restart**: all services lose the database for a few seconds and reconnect. Do it at a quiet time. `make backup` first.
4. Check: `SELECT count(*) FROM pg_stat_statements;` in database `postgres` returns a number (no "must be loaded via shared_preload_libraries" error), and `SHOW shared_preload_libraries;`.

On a fresh prod volume, `02-create-monitor-role.sh` runs only if `JBH_PG_MONITOR_PASSWORD` reaches the container (the guard in D7 skips it otherwise). `jbh-postgres` in prod receives `JBH_PG_MONITOR_PASSWORD: ${JBH_PG_MONITOR_PASSWORD:?set JBH_PG_MONITOR_PASSWORD in .env}`.

### Series budget (prod, free plan: 10,000 for everything; target <= 6,000)

Local rows as above, plus: VPS host (`cpu`, `meminfo`, `filesystem`, `loadavg`, `netdev`) about 250 series (2 vCPU x 8 modes, about 50 memory series, a few mounts, a few interfaces). Total 4,600; headroom 1,400 below the 6,000 target; 5,400 below the plan limit of 10,000.
Guard: if the real total passes 6,000, first lower the number of `pg_stat_statements` rows, then drop `netdev` from `set_collectors`.

### Concurrency and risks (prod)

- Planned recreate of `jbh-postgres` on the VPS while services use it (several writers, short outage). Proposed guard: a quiet time, `make backup` first, services reconnect by themselves (documented in `DEPLOY.md`). No code guard.
- Order of the manual SQL and `make up`: if `make up` runs first, the scrape logs an authentication error until the role exists, then recovers. Documented order (SQL, then `make up`). Harmless either way.
- One container writes `jbh-alloy-data`. A second Alloy on the same volume would corrupt the WAL: compose runs one replica.
- The VPS `.env` must hold the new variables before the next `make up` or `make deploy`, or compose stops at once (`:?` guards). The `Deploy` workflow fails the same way. VPS memory goes from about 3.3 GB to about 3.5 GB.
- Host collectors run as uid 473 without capabilities. If one fails with "permission denied", add `cap_add: [DAC_READ_SEARCH]` (D2). Not verifiable from a laptop.
- The Grafana Cloud endpoints (OTLP gateway, Prometheus URL, instance IDs) differ per stack. They are placeholders in `.env.example` and are copied from the Cloud portal.
