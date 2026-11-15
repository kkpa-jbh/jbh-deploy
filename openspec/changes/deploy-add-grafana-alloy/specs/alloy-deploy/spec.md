## ADDED Requirements

### Requirement: Alloy configuration is shared modules plus two entry files
`observability/alloy/` SHALL contain `modules/otlp.alloy`, `modules/jbh-scrape.alloy`, `modules/postgres.alloy`, `modules/host.alloy`, `local.alloy` and `prod.alloy`.
Each module SHALL hold one custom component (`declare`). Each file SHALL start with a header comment that says what it does, who imports it and which env vars it reads.
No file SHALL contain a secret value: every environment-specific value is an argument or `sys.env(...)`.

#### Scenario: Every file has a header
- **WHEN** the first lines of each of the six `.alloy` files are read
- **THEN** each starts with a comment with what the file does, who imports it and which env vars it reads

#### Scenario: Production has no Faro receiver, local has no host module
- **WHEN** `prod.alloy` and `local.alloy` are read
- **THEN** `prod.alloy` uses `jbh.host` and has no `faro.receiver`, and `local.alloy` has `faro.receiver` on port `12347` with CORS origin `http://localhost:8100` and does not use `jbh.host`

### Requirement: Scraped metrics keep their names
Alloy SHALL send scraped metrics with `prometheus.remote_write` (locally to `http://host.docker.internal:9090/api/v1/write`, in prod to `GRAFANA_CLOUD_PROM_URL`).
The four backends SHALL be scraped every 30 seconds at `jbh-iam:9999/actuator/prometheus`, `jbh-gateway:8080/actuator/prometheus`, `jbh-personal-finance:7777/q/metrics`
and `jbh-notification:7778/q/metrics` (locally on `host.docker.internal`, in prod on the Docker service names), with `honor_labels = true` and a `service` target label.

#### Scenario: Local targets
- **WHEN** `local.alloy` instantiates `jbh.jbh_scrape`
- **THEN** every host is `host.docker.internal`

#### Scenario: Production targets
- **WHEN** `prod.alloy` instantiates `jbh.jbh_scrape`
- **THEN** the hosts are `jbh-iam`, `jbh-gateway`, `jbh-personal-finance` and `jbh-notification`

### Requirement: OTLP intake sets the environment attribute
The module `jbh.otlp` SHALL listen for OTLP on gRPC `0.0.0.0:4317` and HTTP `0.0.0.0:4318`, apply `otelcol.processor.memory_limiter` and `otelcol.processor.batch`,
and set the resource attribute `deployment.environment.name` from its `environment` argument only when the telemetry does not carry it.

#### Scenario: Environment value per entry file
- **WHEN** `local.alloy` and `prod.alloy` are read
- **THEN** `environment` is `local` in the first and `prod` in the second

### Requirement: Production compose runs jbh-alloy privately
`compose.yaml` SHALL define service `jbh-alloy` with image `grafana/alloy:v1.22.0`, no `ports`, no `expose`, only the network `jbh-private`, memory limit `${ALLOY_MEM_LIMIT:-256M}`,
`cap_drop: ALL`, `no-new-privileges:true`, `read_only: true`, a named volume for `/var/lib/alloy/data`, the config folder mounted read-only at `/etc/alloy`,
`/proc`, `/sys` and `/` mounted read-only at `/host/proc`, `/host/sys` and `/host/root`, and a healthcheck on `/-/ready`.
It SHALL NOT mount the Docker socket. No service in `compose.yaml` SHALL publish a host port.

#### Scenario: Service is private and limited
- **WHEN** `docker compose --env-file .env.example -f compose.yaml config` renders `jbh-alloy`
- **THEN** its networks are only `jbh-private`, it has no published or exposed port, its memory limit is 256M, and no volume has the source `/var/run/docker.sock`

#### Scenario: Cloud settings are required
- **WHEN** `GRAFANA_CLOUD_API_TOKEN` is not set in the env file
- **THEN** `docker compose config` fails with `set GRAFANA_CLOUD_API_TOKEN in .env`

### Requirement: Backends know where to send OTLP
In `compose.yaml`, `jbh-iam`, `jbh-gateway`, `jbh-personal-finance` and `jbh-notification` SHALL set `OTEL_EXPORTER_OTLP_ENDPOINT=http://jbh-alloy:4317`, `OTEL_SDK_DISABLED=false`,
`OTEL_TRACES_SAMPLER_ARG=${OTEL_TRACES_SAMPLER_ARG:-1.0}` and `JBH_ENV=prod`, with no `depends_on` on `jbh-alloy`.
In `compose.local.yaml` the same four SHALL set `OTEL_EXPORTER_OTLP_ENDPOINT=http://jbh-alloy:4317`, `OTEL_SDK_DISABLED=false` and `JBH_ENV=local`.

#### Scenario: Names are exact
- **WHEN** the four backends are rendered from `compose.yaml`
- **THEN** each has the four variables above with the values `http://jbh-alloy:4317`, `false`, `1.0` and `prod`

### Requirement: Local Alloy publishes on loopback only
`compose.local.yaml` SHALL define `jbh-alloy` with exactly these published ports, all bound to `127.0.0.1`: `14317:4317`, `14318:4318`, `12347:12347`, `12345:12345`,
and SHALL run `/etc/alloy/local.alloy`.

#### Scenario: Ports do not clash with the local LGTM
- **WHEN** `compose.local.yaml` is rendered
- **THEN** the host ports of `jbh-alloy` are `14317`, `14318`, `12347` and `12345`, none is `4317` or `4318`

### Requirement: Env files and Make targets
`.env.example` SHALL list `GRAFANA_CLOUD_OTLP_ENDPOINT`, `GRAFANA_CLOUD_INSTANCE_ID`, `GRAFANA_CLOUD_API_TOKEN`, `GRAFANA_CLOUD_PROM_URL`, `GRAFANA_CLOUD_PROM_USER`,
`JBH_PG_MONITOR_PASSWORD`, `ALLOY_MEM_LIMIT` and `OTEL_TRACES_SAMPLER_ARG` with placeholders; `.env.local.example` SHALL list `JBH_PG_MONITOR_PASSWORD`.
`Makefile` SHALL have `alloy-logs` and `alloy-ui`; `local.mk` SHALL have `local-alloy`. `ci-deploy.sh` and `.github/workflows/deploy.yml` SHALL NOT change.

#### Scenario: Static checks pass
- **WHEN** `docker compose --env-file .env.example -f compose.yaml config -q` and `docker compose --env-file .env.local.example -f compose.local.yaml config -q` run
- **THEN** both exit 0 with no output

#### Scenario: Deploy boundary is untouched
- **WHEN** `git diff --stat -- ci-deploy.sh .github` runs after the change
- **THEN** it is empty
