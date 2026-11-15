## Context

JBH-55 section 1. Alloy is the single collector. Backends push OTLP (traces, logs) to it. Alloy scrapes the Prometheus endpoints of the
four backends, reads Postgres and (in prod) the VPS host, then sends everything to one destination: the local LGTM or Grafana Cloud.
Decisions already made by the user (Step 2, binding): prod backend = Grafana Cloud; Alloy runs locally and in prod; layout = shared
`modules/` + `local.alloy` + `prod.alloy`; logs over OTLP, no Docker socket; JVM metrics only (no cAdvisor); keep VPS host metrics;
Postgres = basic metrics + `pg_stat_statements`; prod Faro goes straight to Grafana Cloud; local `faro.receiver` on `12347`.

Verified facts:

- Local LGTM (`../kkpa-docker-lab/lgtm`): image `grafana/otel-lgtm:0.12.0`, host ports `3000`, `4317`, `4318`, `9090`. Only these four are published:
  Loki (`3100`) is not reachable from the host. Its Prometheus config scrapes `jbh-personal-finance` and `jbh-iam` itself.
- Backend metric endpoints: `jbh-iam:9999/actuator/prometheus`, `jbh-gateway:8080/actuator/prometheus`, `jbh-personal-finance:7777/q/metrics`,
  `jbh-notification:7778/q/metrics`. Finance, notification and IAM already add a `service` tag (and `env`) to every metric.
- `jbh-postgres` is `postgres:16-alpine`, no `command:` today, no host port in prod. `initdb/` has one script (`01-create-databases.sh`).
- `grafana/alloy` (Docker Hub, checked 2026-11-15): latest stable `v1.22.0` (pushed 2026-11-13; `v1.22.0-rc.0` before it). The image is Ubuntu 24.04 based,
  has no `curl` and no `wget`, runs as root by default, and ships user `alloy` (uid 473) that owns `/var/lib/alloy/data`.
- Library docs were checked with Context7 (`/websites/grafana_alloy`, `/grafana/docker-otel-lgtm`) on 2026-11-15. Where they differ from the plan, see "Deviations from the plan".

## Decisions

### D1. Layout: modules as custom components, two entry files

`observability/alloy/modules/*.alloy` each hold one `declare` block (arguments in, no secret inside). `local.alloy` and `prod.alloy` do
`import.file "jbh" { filename = "/etc/alloy/modules" }`. A directory import is one module namespace, so the four components are used as `jbh.otlp`,
`jbh.jbh_scrape`, `jbh.postgres`, `jbh.host`. Only the entry file differs between local and prod: exporters, hosts, Faro, host module.
Everything that changes between environments is an argument or `sys.env(...)`. No secret is in a file.
Every file starts with a header comment: what it does, who imports it, which env vars it reads. The files contain only `declare`, `import.file` and
components, so they can move into Helm values (`alloy.configMap.content`) later.
Why custom components and not one file per environment: one pipeline definition, tested in local, runs in prod. Rejected: `import.git` (needs network at start, no gain here).

### D2. Image pin, user and healthcheck

Image `grafana/alloy:v1.22.0` (pinned, never `latest`). It is the newest stable tag on Docker Hub (2026-11-13). If it misbehaves, `v1.21.0` is the fallback tag (same config).
Command: `run --server.http.listen-addr=0.0.0.0:12345 --storage.path=/var/lib/alloy/data /etc/alloy/prod.alloy`. Flags go before the config path.
`user: "473:473"` in both compose files: the named volume is created from the image folder, owned by uid 473 and mode 770. A root user with `cap_drop: ALL`
could not write there (no `DAC_OVERRIDE`). Host procfs, sysfs and root mounts are world-readable for the collectors we keep.
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
Fallback if a host collector gets "permission denied" on the VPS: keep `user` and add `cap_add: [DAC_READ_SEARCH]`. Check on first start (DEPLOY.md).

### D3. Metrics path: `prometheus.remote_write` (local and prod)

Scraped metrics go to `prometheus.remote_write`, so metric names and labels stay exactly as today (the circuit breaker dashboard keeps working).
- **Local:** the `otel-lgtm` Prometheus accepts remote write. Verified in the image source (`grafana/docker-otel-lgtm`, tag `v0.12.0`, `docker/run-prometheus.sh`):
  it starts Prometheus with `--web.enable-remote-write-receiver` (and `--web.enable-otlp-receiver`). URL: `http://host.docker.internal:9090/api/v1/write`, no auth.
  Its `prometheus.yaml` is untouched, so no edit of `kkpa-docker-lab` is needed.
- **Prod:** `GRAFANA_CLOUD_PROM_URL` (the remote-write URL from the Cloud portal) with `basic_auth` user `GRAFANA_CLOUD_PROM_USER` and password `GRAFANA_CLOUD_API_TOKEN`.
- Rejected: `otelcol.receiver.prometheus` -> OTLP. The OTLP path to Prometheus rewrites names (dots, unit suffixes, `_total`), which would break the dashboard and the PromQL names the services expect.
- Alloy WAL: `--storage.path` is a named volume, so queued samples survive a restart.

### D4. OTLP export: gRPC locally, HTTP to Grafana Cloud

- Local: `otelcol.exporter.otlp "lgtm"` to `host.docker.internal:4317`, `tls { insecure = true }`, no auth.
- Prod: `otelcol.exporter.otlphttp "cloud"` to `sys.env("GRAFANA_CLOUD_OTLP_ENDPOINT")` (the OTLP gateway, `https://otlp-gateway-<zone>.grafana.net/otlp`), with `otelcol.auth.basic`
  (`client_auth` block: user `GRAFANA_CLOUD_INSTANCE_ID`, password `GRAFANA_CLOUD_API_TOKEN`). The gateway speaks OTLP over HTTP, so `otlphttp` and not `otlp`.
The exporters live in the entry files (they are the environment-specific part). The `jbh.otlp` module receives them as an `output` argument.

### D5. `deployment.environment.name`: `otelcol.processor.transform`

The attribute is a resource attribute. `otelcol.processor.attributes` works on span, log and datapoint attributes, not on the resource. `otelcol.processor.transform` with `context = "resource"` is documented for it.
The module `jbh.otlp` sets it from its `environment` argument only when the service did not set it (`where attributes["deployment.environment.name"] == nil`).
The OTTL statement is a string, so the argument is joined with `+`. `error_mode = "ignore"`: a bad statement never drops data.
Pipeline order inside the module: `otelcol.receiver.otlp` (gRPC `0.0.0.0:4317`, HTTP `0.0.0.0:4318`) -> `otelcol.processor.memory_limiter` (`check_interval = "1s"`,
`limit_percentage = 75`, `spike_limit_percentage = 15`: percent of the container limit, so `ALLOY_MEM_LIMIT` can change) -> `otelcol.processor.transform` -> `otelcol.processor.batch` (defaults) -> `output` argument.
Rejected: `otelcol.processor.resourcedetection` with the `env` detector (hides the value in a container env var instead of an argument).

### D6. Scrape module: one scrape component per backend

`jbh.jbh_scrape` has arguments `hosts` (object: service name -> host) and `forward_to`. It holds four `prometheus.scrape` components, one per backend, each with its own `job_name`
(the service name), `metrics_path`, `scrape_interval = "30s"`, `scrape_timeout = "10s"`, one target `<host>:<port>` and the target label `service = <name>`.
Ports and paths are fixed in the module (they belong to the services); only the hosts differ: local `host.docker.internal` for all four, prod the service names.
Why four components and not one with `__metrics_path__` labels: `job_name` is explicit, no doubt about the `job` label. Why not a loop: Alloy has none for components.
`honor_labels = true`: finance, notification and IAM already expose a `service` tag; with the default, Prometheus would rename it to `exported_service`. With `true` the exposed value wins and the target label fills the gap (the gateway has none).

### D7. Postgres module

`jbh.postgres` (arguments `dsn`, `forward_to`): `prometheus.exporter.postgres` with `data_source_names = [argument.dsn.value]` and `enabled_collectors` = the Alloy defaults
(`database`, `locks`, `replication`, `replication_slot`, `roles`, `stat_bgwriter`, `stat_database`, `stat_progress_vacuum`, `stat_user_tables`, `statio_user_tables`, `wal`) plus `stat_statements`.
The docs list the defaults and say `enabled_collectors` "controls a subset"; they do not say that it adds to the defaults. So the list is explicit.
Then `prometheus.scrape` (`job_name = "jbh-postgres"`, `service = "jbh-postgres"`, 30s). The DSN: `postgresql://jbh_monitor:<password>@jbh-postgres:5432/postgres?sslmode=disable`,
built in compose from `JBH_PG_MONITOR_PASSWORD` and passed as env `JBH_PG_MONITOR_DSN`. The password must be URL-safe (`openssl rand -hex 24`), because it sits inside a URL.
The exporter connects only to database `postgres` (no `autodiscover_databases`), so the per-table collectors find no user tables and add almost no series.

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

### D11. Local compose and Faro

`jbh-alloy` in `compose.local.yaml`: same image and user, `<<: *app-host` (`host.docker.internal:host-gateway`), command with `/etc/alloy/local.alloy`, no hardening block (the local file has none for any service),
no host mounts, no `depends_on`. Ports, all on `127.0.0.1` only: `127.0.0.1:14317:4317`, `127.0.0.1:14318:4318` (the local LGTM owns `4317`/`4318`), `127.0.0.1:12347:12347` (Faro), `127.0.0.1:12345:12345` (Alloy UI).
Env: `JBH_PG_MONITOR_DSN: postgresql://jbh_monitor:${JBH_PG_MONITOR_PASSWORD:?...}@jbh-postgres:5432/postgres?sslmode=disable`. A named volume `jbh-local-alloy-data`.
The Docker backends get `OTEL_EXPORTER_OTLP_ENDPOINT: http://jbh-alloy:4317`, `OTEL_SDK_DISABLED: "false"`, `JBH_ENV: local`. A service in the IDE sends to `http://localhost:14317` (written in `LOCAL.md`).
`local.alloy`: targets on `host.docker.internal` (the same ports are published for Docker and IDE services); no host module; `faro.receiver "app"` with `listen_address = "0.0.0.0"` (inside the container; the host side is `127.0.0.1` only),
`listen_port = 12347`, `cors_allowed_origins = ["http://localhost:8100"]`.
Faro `output`: traces go to `otelcol.exporter.otlp.lgtm.input`. Logs go through `otelcol.receiver.loki` to the same OTLP exporter, because Loki's own port (`3100`) is not published by the local LGTM; the LGTM collector routes OTLP logs to Loki.

### D12. Env files

`.env.example` (new block "Observability"): `GRAFANA_CLOUD_OTLP_ENDPOINT=https://otlp-gateway-prod-change-me.grafana.net/otlp`, `GRAFANA_CLOUD_INSTANCE_ID=change-me`, `GRAFANA_CLOUD_API_TOKEN=change-me`,
`GRAFANA_CLOUD_PROM_URL=https://prometheus-prod-change-me.grafana.net/api/prom/push`, `GRAFANA_CLOUD_PROM_USER=change-me`, `JBH_PG_MONITOR_PASSWORD=change-me`, `ALLOY_CPU_LIMIT=0.25`, `ALLOY_MEM_LIMIT=256M`, `OTEL_TRACES_SAMPLER_ARG=1.0`.
The memory total in its limits comment becomes "about 3.5 GB". `.env.local.example`: only `JBH_PG_MONITOR_PASSWORD=change-me` (with the URL-safe note). Placeholders are non-empty so the static check passes.

### D13. Make targets

`Makefile`: `alloy-logs` (`$(COMPOSE) logs -f --tail=200 jbh-alloy`), `alloy-ui` (prints the SSH tunnel command to the container IP and port `12345`, same pattern as `consul-tunnel`), both in `.PHONY` and `help`.
`local.mk`: `local-alloy` (checks `.env.local`, then `$(LOCAL_COMPOSE) up -d jbh-alloy`; for IDE work), in `.PHONY`; the `help` line in the `Makefile` gets it.
`ci-deploy.sh` and `deploy.yml` do not change: `jbh-alloy` is not one of the 5 app services and is deployed by `make up`. To restart it after a config change: `make up` (config is a bind mount; `docker compose restart jbh-alloy` is enough, noted in DEPLOY.md).

### D14. Docs

- `README.md`: Alloy in the "Production" picture and the env table (new row `jbh-alloy`, OTLP variables on the four backends, the `jbh-postgres` row), memory note 3.5 GB, Postgres paragraph (monitor role, `pg_stat_statements`), a short "Observability" paragraph, the dev OTLP port `14317`, `ci-deploy.sh` still lists 5 services.
- `LOCAL.md`: start the local LGTM (`make lgtm up` style command in `kkpa-docker-lab`, as that repo documents), then `make local-up` (Alloy starts with it) or `make local-alloy` alone; ports table (`14317`, `14318`, `12347`, `12345`); the IDE OTLP value `http://localhost:14317`; where to see data in Grafana (`http://localhost:3000`, Explore).
- `DEPLOY.md`: new section 8 "Observability (Grafana Alloy)": create the Grafana Cloud stack and an access policy token (scopes: `metrics:write`, `logs:write`, `traces:write`), where each value goes in `.env`, the one-time Postgres SQL and restart, first start, how to check that data arrives, rows in "When something is wrong". Update section 7 (memory) and the first-deploy list.
- `observability/README.md`: series budget table; "Where the metrics come from" says Alloy scrapes in both places; add the gateway, Postgres and host rows; fix the status note.
- `CLAUDE.md`: files table rows for `observability/alloy/` and the new `initdb/` script. The Rules section does not change.

## Deviations from the plan (docs win)

| Plan said | Docs say | Used |
|-----------|----------|------|
| `otelcol.auth.basic` `username`/`password` | top-level `username`/`password` are deprecated; use a `client_auth` block | `client_auth { ... }` |
| Cloud export through `otelcol.exporter.otlp` (implied) | Grafana Cloud OTLP gateway example uses `otelcol.exporter.otlphttp` | `otlphttp` in prod, `otlp` (gRPC) locally |
| Faro logs to Loki | Loki `3100` is not published by the local LGTM | `otelcol.receiver.loki` -> OTLP exporter |
| Attribute step (`attributes`/`resource`) | `otelcol.processor.attributes` is not for resource attributes; `otelcol.processor.resource` has no entry in the docs | `otelcol.processor.transform`, `context = "resource"` |
| `faro.receiver` default | `listen_address` default is `127.0.0.1` | `0.0.0.0` in the container, host side bound to `127.0.0.1` |

## Test contract (expected values)

No unit tests and no integration tests: this repo holds config and docs only, and the JBH-55 plan excludes unit tests. **No test blueprint group.**
Verification is static. The leader runs V1-V3 with the build step; the user runs the optional checks.

| # | Check | Expected |
|---|-------|----------|
| V1 | `docker compose --env-file .env.example -f compose.yaml config -q` | exit 0, no output |
| V2 | `docker compose --env-file .env.local.example -f compose.local.yaml config -q` | exit 0, no output |
| V3 | `docker compose --env-file .env.example -f compose.yaml config --services` | 8 services, including `jbh-alloy` |
| V4 | `config` of `compose.yaml`, service `jbh-alloy` | image `grafana/alloy:v1.22.0`; networks only `jbh-private`; no `ports`, no `expose`; memory limit 268435456 (256M); `cap_drop` ALL; `read_only` true; `user` `473:473`; no volume whose source is `/var/run/docker.sock`; five volumes (config, data, `/proc`, `/sys`, `/`); healthcheck mentions `/-/ready` |
| V5 | same output, no service has `ports` | `grep -c "published:"` on the rendered output is 0 |
| V6 | same output, services `jbh-iam`, `jbh-gateway`, `jbh-personal-finance`, `jbh-notification` | each has `OTEL_EXPORTER_OTLP_ENDPOINT` = `http://jbh-alloy:4317`, `OTEL_SDK_DISABLED` = `false`, `OTEL_TRACES_SAMPLER_ARG` = `1.0`, `JBH_ENV` = `prod` |
| V7 | same output, service `jbh-postgres` | command has `shared_preload_libraries=pg_stat_statements` and `pg_stat_statements.track=top`; env `JBH_PG_MONITOR_PASSWORD` = `change-me` |
| V8 | `compose.yaml` with an env file that lacks `GRAFANA_CLOUD_API_TOKEN` | `config` fails with `set GRAFANA_CLOUD_API_TOKEN in .env` |
| V9 | `config` of `compose.local.yaml`, service `jbh-alloy` | exactly four published ports, each with `host_ip` `127.0.0.1`: `14317`->`4317`, `14318`->`4318`, `12347`->`12347`, `12345`->`12345`; command ends with `/etc/alloy/local.alloy` |
| V10 | same output, the four backends | `OTEL_EXPORTER_OTLP_ENDPOINT` = `http://jbh-alloy:4317`, `OTEL_SDK_DISABLED` = `false`, `JBH_ENV` = `local`; `jbh-postgres` has the same two `-c` options |
| V11 | `head -n 15` of each of the six `.alloy` files | a header comment: what it does, who imports it, which env vars it reads |
| V12 | `grep -rn "docker.sock" compose.yaml compose.local.yaml observability/` | no match (only prose in docs may say "no Docker socket") |
| V13 | `git diff --stat -- ci-deploy.sh .github jbh.caddy` | empty |
| V14 | `sh -n initdb/02-create-monitor-role.sh` | exit 0 |
| V15 | `grep -n "sys.env" observability/alloy/prod.alloy` | five Grafana Cloud variables and `JBH_PG_MONITOR_DSN`; no literal token or password anywhere under `observability/alloy/` |
| V16 (optional, user) | `docker run --rm -e GRAFANA_CLOUD_OTLP_ENDPOINT=https://x -e GRAFANA_CLOUD_INSTANCE_ID=1 -e GRAFANA_CLOUD_API_TOKEN=x -e GRAFANA_CLOUD_PROM_URL=https://x/api/prom/push -e GRAFANA_CLOUD_PROM_USER=1 -e JBH_PG_MONITOR_DSN=postgresql://u:p@h:5432/postgres -v "$PWD/observability/alloy:/etc/alloy:ro" grafana/alloy:v1.22.0 validate /etc/alloy/prod.alloy` and the same with `local.alloy` (only `JBH_PG_MONITOR_DSN` needed) | exit 0 (`alloy validate` returns non-zero with diagnostics on stderr when the config is invalid). Also `alloy fmt` for formatting. Nothing in this pipeline runs Alloy. |

## Database

Planned database change (design gate `database`). No table, column, index or Liquibase migration. The change is one role, one grant and one extension.

**Objects**

| Object | Value |
|--------|-------|
| Role | `jbh_monitor`, `LOGIN`, password `JBH_PG_MONITOR_PASSWORD` (not superuser, no `CREATEDB`) |
| Grant | `GRANT pg_monitor TO jbh_monitor` (predefined role: includes `pg_read_all_stats`, `pg_read_all_settings`, `pg_stat_scan_tables`) |
| Extension | `CREATE EXTENSION IF NOT EXISTS pg_stat_statements` in database `postgres` |
| Server settings | `shared_preload_libraries=pg_stat_statements` and `pg_stat_statements.track=top`, as `-c` options of the `jbh-postgres` command in both compose files |

**First start (empty volume)** - `initdb/02-create-monitor-role.sh` (shell, so it reads the password from env; it runs after `01-create-databases.sh` by file name):

```sh
psql -v ON_ERROR_STOP=1 -v pw="$JBH_PG_MONITOR_PASSWORD" --username "$POSTGRES_USER" --dbname postgres <<'SQL'
CREATE ROLE jbh_monitor LOGIN PASSWORD :'pw';
GRANT pg_monitor TO jbh_monitor;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
```

`:'pw'` is psql's quoted-literal interpolation, so the password is escaped by psql and never concatenated into SQL. `jbh-postgres` receives `JBH_PG_MONITOR_PASSWORD: ${JBH_PG_MONITOR_PASSWORD:?set JBH_PG_MONITOR_PASSWORD in .env}` (in `.env.local` for the local file).

**Existing VPS database** - `initdb/` does not run on a non-empty volume, so `DEPLOY.md` section 8 gets a one-time step, in this order:
1. Put the new variables in the VPS `.env` (all of them, before any `make` command).
2. Run the same SQL by hand against the running container (`docker compose --env-file .env -f compose.yaml exec -T jbh-postgres psql -U "$POSTGRES_USER" -d postgres -v pw=... `): `CREATE ROLE`, `GRANT pg_monitor`, `CREATE EXTENSION IF NOT EXISTS pg_stat_statements`. The extension and the role work before the restart; only the view needs the library.
3. `make up`: compose recreates `jbh-postgres` because its command changed. **This is the planned restart**: all services lose the database for a few seconds and reconnect. Do it at a quiet time. `make backup` first.
4. Check: `SELECT count(*) FROM pg_stat_statements;` in database `postgres` returns a number (no "must be loaded via shared_preload_libraries" error), and `SHOW shared_preload_libraries;`.

**Why this design:**
- A dedicated least-privilege role: `pg_monitor` reads statistics only. Rejected: using `POSTGRES_USER` (admin) for the exporter: a leaked DSN would own all data.
- The extension is created once in database `postgres`: `pg_stat_statements` collects for the whole cluster, and the view in one database shows rows for all databases. Rejected: creating it in `jbh` and `jbh_finance` too (two more places, more exporter connections, same data).
- `pg_stat_statements.track=top` counts only top-level statements (not statements inside functions): fewer rows, less overhead. Rejected: `all`.
- The exporter connects to database `postgres` only. Rejected: `autodiscover_databases` (more series and connections for no gain on a VPS with a 512M Postgres).
- Not a Liquibase change: no JBH service owns this role. `initdb/` already holds the cluster-level setup (`pgcrypto`, time zone).
- `postgres:16-alpine` ships the `contrib` modules, so `pg_stat_statements` needs no new image.

**Index plan: none needed.** No table is created or changed, so there is no index to add. The only reader is the exporter: every 30 seconds it reads the `pg_stat_statements` view (one cluster-wide scan of an in-memory hash table, 5000 entries at most by default, `pg_stat_statements.max`) and the `pg_stat_*` views. These are system views over shared memory, not heap tables with indexes. No read pattern of any JBH service touches them.
Memory cost: `pg_stat_statements` uses a few MB of shared memory (fixed size); the `jbh-postgres` limit of 512M stays.

## Series budget (prod, free plan: 10,000 for everything; target <= 6,000)

Estimates from the typical size of each endpoint. The real counts are a user step (`curl -s <url> | grep -vc '^#'`); each service section of JBH-55 reports its own, and `observability/README.md` holds the table that the user updates.

| Source | Estimate | Note |
|--------|---------:|------|
| `jbh-iam` (Spring, Micrometer) | 1,000 | JVM, Tomcat/Hikari, HTTP histograms |
| `jbh-gateway` (Spring Cloud Gateway) | 700 | JVM, Netty, route and HTTP metrics |
| `jbh-personal-finance` (Quarkus) | 1,200 | JVM, Agroal, HTTP histograms (11 buckets) per endpoint |
| `jbh-notification` (Quarkus) | 600 | JVM, Agroal, few endpoints |
| Postgres, default collectors (database `postgres` only) | 350 | `stat_database` for 4 databases, `locks`, `wal`, `roles`, `stat_bgwriter` |
| Postgres `stat_statements` | 500 | about 100 statements x 5 counters (calls, rows, time, blocks read/written) |
| VPS host (`cpu`, `meminfo`, `filesystem`, `loadavg`, `netdev`) | 250 | 2 vCPU x 8 modes, about 50 memory series, a few mounts, a few interfaces |
| Alloy itself | 0 | `include_exporter_metrics` off, Alloy's own metrics are not scraped |
| **Total** | **4,600** | headroom 1,400 below the 6,000 target; 5,400 below the plan limit of 10,000 |

Guard: if the real total passes 6,000, first lower the number of `pg_stat_statements` rows, then drop `netdev` from `set_collectors`. Traces and logs have their own quotas (50 GB, 14 days) and no series.

## Concurrency

Task numbers refer to `tasks.md`.

- **Tasks 4.1 and 8.3 (Postgres restart on the VPS).** Risk: a planned recreate of `jbh-postgres` while other services use it (several writers, short outage). Proposed guard: do it at a quiet time, `make backup` first, services reconnect by themselves (documented in `DEPLOY.md`). No code guard.
- **Task 8.3 (order of the manual SQL and `make up`).** Risk: check-then-act between "role exists" and the first Alloy scrape. If `make up` runs first, the scrape logs an authentication error until the role exists, then recovers. Proposed guard: documented order (SQL, then `make up`). Harmless either way.
- **Tasks 5.1 and 8.2 (local metrics stored twice).** Risk: two writers for the same series: the local Prometheus scrape jobs of `kkpa-docker-lab` and Alloy's remote write. Proposed guard: ask the docker-lab owner to remove the `jbh-personal-finance` and `jbh-iam` jobs (report item, not a file edit).
- **Tasks 4.1 and 5.1 (Alloy WAL volume).** One container writes `jbh-alloy-data`. A second Alloy on the same volume would corrupt the WAL: compose runs one replica, and local and prod use different volume names and hosts. No guard needed.
- No shared memory, no async code, no handler that can run twice in this change. Alloy's own queues and retries are inside Alloy.

## Responsibilities

| File | One job | Who asks to change it |
|------|---------|-----------------------|
| `observability/alloy/modules/otlp.alloy` | Receive OTLP, limit memory, set the environment attribute, batch, forward | Whoever changes OTLP intake or sampling of resource data |
| `observability/alloy/modules/jbh-scrape.alloy` | Scrape the four backends (names, ports, paths, interval) | A service changes port or metrics path |
| `observability/alloy/modules/postgres.alloy` | Expose and scrape Postgres metrics | The Postgres metric set changes |
| `observability/alloy/modules/host.alloy` | Expose and scrape VPS host metrics | The host metric set changes |
| `observability/alloy/local.alloy` | Local wiring: hosts, Faro, local exporters | The local LGTM or the local ports change |
| `observability/alloy/prod.alloy` | Production wiring: hosts, host module, Grafana Cloud exporters | Grafana Cloud endpoints or auth change |
| `initdb/02-create-monitor-role.sh` | Create the monitor role, grant and extension on a new volume | The monitoring user or extension changes |
| `compose.yaml` | Prod service definitions; gains `jbh-alloy`, OTLP variables, Postgres options | Prod topology changes |
| `compose.local.yaml` | Local service definitions; gains `jbh-alloy`, OTLP variables, Postgres options | Local topology changes |
| `.env.example`, `.env.local.example` | List every variable with a placeholder | A variable is added or renamed |
| `Makefile`, `local.mk` | Operator commands (VPS / laptop) | An operator task changes |
| `README.md` | System map | A route, port, env var or service changes |
| `LOCAL.md` / `DEPLOY.md` | Laptop runbook / VPS runbook | A step changes |
| `observability/README.md` | Observability guide and series budget | A signal or its source changes |
| `CLAUDE.md` | Repo files table and rules | A file is added |

Existing files get a new job only as listed (for example `compose.yaml` hosts one more service). No file takes a second reason to change.

## Risks / Trade-offs

- The VPS `.env` must hold the new variables before the next `make up` or `make deploy`, or compose stops at once (`:?` guards, like the other secrets). The `Deploy` workflow fails the same way. DEPLOY.md section 8 puts this step first.
- Host collectors run as uid 473 without capabilities. If one fails with "permission denied" on the VPS, add `cap_add: [DAC_READ_SEARCH]` (D2). Not verifiable from a laptop.
- `alloy validate` cannot prove the custom-component argument wiring for `otelcol` consumers (`argument "output"`). If it fails, the fallback is to export `input` from `jbh.otlp` and wire the exporter in the entry file; no other file changes.
- v1.22.0 is two days old. Fallback tag `v1.21.0`.
- The Grafana Cloud endpoints (OTLP gateway, Prometheus URL, instance IDs) differ per stack. They are placeholders in `.env.example` and are copied from the Cloud portal (DEPLOY.md).
- `pg_stat_statements` query text may contain literal values. The exporter does not export query text by default (`include_query` off in the upstream exporter); only a hash id is a label. Keep it that way.

## Not included

- Dashboards and alert rules (later sections of JBH-55), the Grafana Cloud stack itself (user step), changes in the services.
- `faro.receiver` in prod, Docker socket, cAdvisor, container log scraping, Alloy clustering.
- Edits to `ci-deploy.sh`, `.github/workflows/deploy.yml`, `jbh.caddy`, `CI.md`, `../kkpa-docker-lab`.
- Helm values (the files are written so they can move there later).
- Any test code (no unit tests, no integration tests).

## Report item for the leader (not a file edit)

Tell the user: remove the `jbh-personal-finance` and `jbh-iam` jobs from `../kkpa-docker-lab/lgtm/prometheus.yaml`, or local metrics are stored twice.
