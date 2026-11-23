# alloy-deploy Specification

## Purpose
TBD - created by archiving change deploy-add-grafana-alloy. Update Purpose after archive.
## Requirements
### Requirement: Alloy configuration is shared modules plus a local entry file
`observability/alloy/` SHALL contain `modules/otlp.alloy`, `modules/jbh-scrape.alloy`, `modules/postgres.alloy` and `local.alloy`.
Each module SHALL hold one custom component (`declare`) with arguments, so a prod entry file can reuse it later.
Each file SHALL start with a header comment that says what it does, who imports it and which env vars it reads.
No file SHALL contain a secret value: every environment-specific value is an argument or `sys.env(...)`.

#### Scenario: Every file has a header
- **WHEN** the first lines of each of the four `.alloy` files are read
- **THEN** each starts with a comment with what the file does, who imports it and which env vars it reads

#### Scenario: Local entry has a Faro receiver and no host module
- **WHEN** `local.alloy` is read
- **THEN** it has `faro.receiver` on port `12347` with CORS origin `http://localhost:8100`, and it does not use `jbh.host`

### Requirement: Scraped metrics keep their names
Alloy SHALL send scraped metrics with `prometheus.remote_write` to `http://host.docker.internal:9090/api/v1/write`.
The four backends SHALL be scraped every 30 seconds at `jbh-iam:9999/actuator/prometheus`, `jbh-gateway:8080/actuator/prometheus`, `jbh-personal-finance:7777/q/metrics`
and `jbh-notification:7778/q/metrics` (host `host.docker.internal`), with `honor_labels = true` and a `service` target label.

#### Scenario: Local targets
- **WHEN** `local.alloy` instantiates `jbh.jbh_scrape`
- **THEN** every host is `host.docker.internal`

### Requirement: OTLP intake sets the environment attribute
The module `jbh.otlp` SHALL listen for OTLP on gRPC `0.0.0.0:4317` and HTTP `0.0.0.0:4318`, apply `otelcol.processor.memory_limiter` and `otelcol.processor.batch`,
and set the resource attribute `deployment.environment.name` from its `environment` argument only when the telemetry does not carry it.

#### Scenario: Environment value
- **WHEN** `local.alloy` is read
- **THEN** `environment` is `local`

### Requirement: Backends know where to send OTLP
In `compose.local.yaml`, `jbh-iam`, `jbh-gateway`, `jbh-personal-finance` and `jbh-notification` SHALL set `OTEL_EXPORTER_OTLP_ENDPOINT=http://jbh-alloy:4317`,
`OTEL_SDK_DISABLED=false` and `JBH_ENV=local`, with no `depends_on` on `jbh-alloy`.

#### Scenario: Names are exact
- **WHEN** the four backends are rendered from `compose.local.yaml`
- **THEN** each has the three variables above with the values `http://jbh-alloy:4317`, `false` and `local`

### Requirement: Local Alloy publishes on loopback only
`compose.local.yaml` SHALL define `jbh-alloy` with image `grafana/alloy:v1.22.0`, user `473:473`, a healthcheck on `/-/ready`, the config folder mounted read-only at `/etc/alloy`,
a named volume for `/var/lib/alloy/data`, and exactly these published ports, all bound to `127.0.0.1`: `14317:4317`, `14318:4318`, `12347:12347`, `12345:12345`.
It SHALL run `/etc/alloy/local.alloy` and SHALL NOT mount the Docker socket.

#### Scenario: Ports do not clash with the local LGTM
- **WHEN** `compose.local.yaml` is rendered
- **THEN** the host ports of `jbh-alloy` are `14317`, `14318`, `12347` and `12345`, none is `4317` or `4318`

### Requirement: Env placeholder and Make target
`.env.local.example` SHALL list `JBH_PG_MONITOR_PASSWORD` with a placeholder, and `JBH_PG_MONITOR_DSN` as an optional override. `jbh-alloy` SHALL use `JBH_PG_MONITOR_DSN` when it is set, and otherwise a DSN built from `JBH_PG_MONITOR_PASSWORD` for `jbh-postgres`. `local.mk` SHALL have `local-alloy` and `local-alloy-logs`.
`compose.yaml`, `.env.example`, `Makefile`, `DEPLOY.md`, `ci-deploy.sh` and `.github/workflows/deploy.yml` SHALL NOT change.

#### Scenario: Static check passes
- **WHEN** `docker compose --env-file .env.local.example -f compose.local.yaml config -q` runs
- **THEN** it exits 0 with no output

#### Scenario: Production files are untouched
- **WHEN** `git diff --stat -- compose.yaml .env.example Makefile DEPLOY.md ci-deploy.sh .github` runs after the change
- **THEN** it is empty

#### Scenario: DSN default and override
- **WHEN** `compose.local.yaml` is rendered with `.env.local.example`, and again with `JBH_PG_MONITOR_DSN=postgresql://jbh_monitor:x@host.docker.internal:5432/postgres?sslmode=disable` added
- **THEN** the first render shows the `@jbh-postgres:5432/postgres?sslmode=disable` DSN and the second shows the override value

### Requirement: Faro logs carry service.name
`local.alloy` SHALL set the resource attribute `service.name` on Faro logs from the `app_name` field of the log line, before the logs reach `otelcol.exporter.otlp "lgtm"`,
using `otelcol.processor.transform` between `otelcol.receiver.loki "faro"` and the exporter. The Faro traces path SHALL NOT change.

#### Scenario: Faro log in Loki
- **WHEN** the browser app sends a Faro event with `app_name=jbh-web` and Alloy has restarted
- **THEN** Loki shows the line with `service_name="jbh-web"` and not `unknown_service`

#### Scenario: Line without app_name
- **WHEN** a Faro log line has no `app_name`
- **THEN** the line is still forwarded (`error_mode = "ignore"`) and Loki keeps `unknown_service` for it

