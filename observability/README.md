# Observability

How JBH collects logs, metrics and traces, and the Grafana dashboards and alerts for the JBH services.

- New to Grafana? Read [`GUIDE.md`](GUIDE.md).
- Want to check that the local stack works? Follow [`VERIFY.md`](VERIFY.md).

## Tech stack

**Status:** this is the target design of epic JBH-55. It is not all built yet.
Local Alloy is in place (JBH-56): it receives OTLP, scrapes the four backends and Postgres, and feeds the local LGTM.
The services still need their own changes (JBH-57..59, 81..83), and production is JBH-84. Dashboards and alert rules are done (JBH-61).

**OpenTelemetry does not store anything.** It is the standard that *creates* and *sends* data.
Its protocol is **OTLP**. Storage happens in the LGTM stack.

There are 3 layers.

### 1. Inside the apps: create the data

| Tool | Used in | Job |
|------|---------|-----|
| **OpenTelemetry SDK** | all backends | Creates traces, adds `traceId` to every log line, sends traces and logs over OTLP |
| **Micrometer** | all backends | Creates metrics (HTTP latency, JVM memory, DB pool) and exposes them as a Prometheus endpoint |
| **Grafana Faro** | `jbh-app` | Browser SDK: traces, JS errors, web vitals. It uses OpenTelemetry inside |

### 2. In the middle: collect and forward

| Tool | Job |
|------|-----|
| **Grafana Alloy** | The single collector. It receives OTLP, scrapes the Prometheus endpoints, and reads Postgres and VPS host metrics with its built-in exporters. Then it sends everything to one destination: the local LGTM or Grafana Cloud |

### 3. Storage and UI: the LGTM stack

| Letter | Tool | Stores | Local (`kkpa-docker-lab/lgtm`) | Production (Grafana Cloud) |
|--------|------|--------|--------------------------------|----------------------------|
| **L** | **Loki** | logs | yes | yes |
| **G** | **Grafana** | nothing: it is the UI (dashboards, Explore, alerts) | yes | yes |
| **T** | **Tempo** | traces | yes | yes |
| **M** | **Prometheus** locally, **Mimir** in production | metrics | Prometheus | Mimir |

**Mimir** is Grafana's large-scale version of Prometheus. It uses the same query language (PromQL),
so the same dashboards and queries work locally and in production.

Two more pieces:

- **Frontend Observability** (Grafana Cloud only) receives the Faro data in production.
  Locally, Alloy's `faro.receiver` receives it instead.
- **Pyroscope** (CPU and memory profiling) is in the local LGTM image, but JBH does not use it.

### One request, end to end

```
browser (Faro) ─traceparent─► gateway ─► finance ─► gateway ─► iam
      │                         │           │                    │
      └──────── OTLP traces + logs, Prometheus metrics ──────────┘
                                │
                             Alloy
                                │
          local: LGTM container │ production: Grafana Cloud
         Loki · Tempo · Prometheus · Grafana
```

The browser creates the trace id and sends it in the W3C `traceparent` header.
Every service continues that trace. When a call has no `traceparent` (for example `curl` straight to the gateway),
the gateway starts a new trace.

## Dashboards

Each JSON file in `grafana/` is one dashboard.

| File | Shows | Metrics from |
|------|-------|--------------|
| `grafana/jbh-overview.json` (`jbh-overview`) | Per service: up, request rate, 5xx and 4xx share, p95. Links to the other dashboards and to Tempo. Frontend errors from Loki | `up`, `http_server_requests_seconds_*`, Loki `jbh-web` |
| `grafana/jbh-service.json` (`jbh-service`) | One service (pick it in the `service` variable): p50, p95, p99 and errors per `uri`, JVM heap, GC, threads, CPU, DB pool (Agroal or Hikari) | `http_server_requests_seconds_*`, `jvm_*`, `process_cpu_usage`, `agroal_*`, `hikaricp_*` |
| `grafana/jbh-postgres.json` (`jbh-postgres`) | Connections against `max_connections`, transactions, locks, deadlocks, cache hit ratio, size, top queries by total time | `pg_stat_*`, `pg_locks_count`, `pg_settings_max_connections`, `pg_stat_statements_*` |
| `grafana/jbh-traces.json` (`jbh-traces`) | Tempo tables (slowest traces, traces with errors, traces with 3 services), service graph, call rate per client and server | Tempo (TraceQL), `traces_service_graph_request_*` |
| `grafana/jbh-circuit-breakers.json` | Circuit breakers of `jbh-gateway-client`: state, failure rate, calls, rejected calls | `resilience4j_circuitbreaker_*` |

Every dashboard has a fixed `uid` (the file name without `.json`) and a `datasource` variable. No panel has a fixed data source,
so the same file works in the local LGTM and in Grafana Cloud. The services are chosen by the Prometheus `job` label.

## Alerts

Each file in `alerts/` is one alert rule, in the Grafana alert rule provisioning format. The folder in Grafana is `JBH`.
Every rule has an annotation `what_to_check_first`.

| File (`uid`) | Fires when | For | No data |
|--------------|-----------|-----|---------|
| `alerts/jbh-service-down.yaml` (`jbh-alert-service-down`) | `up` is below 1 for a backend, or the metric is missing | 5m | Alerting |
| `alerts/jbh-http-5xx-rate.yaml` (`jbh-alert-http-5xx`) | More than 5% of requests answer 5xx | 5m | OK |
| `alerts/jbh-http-p95-latency.yaml` (`jbh-alert-http-p95`) | p95 latency above 2 s | 10m | OK |
| `alerts/jbh-jvm-heap-high.yaml` (`jbh-alert-heap-high`) | Heap above 90% of its maximum | 10m | OK |
| `alerts/jbh-frontend-error-spike.yaml` (`jbh-alert-frontend-errors`) | More than 10 Faro exceptions in 5 minutes (Loki, `service_name="jbh-web"`) | 5m | OK |
| `alerts/jbh-postgres-connections-high.yaml` (`jbh-alert-pg-connections`) | Connections above 80% of `max_connections`, or the metric is missing | 5m | Alerting |
| `alerts/jbh-postgres-deadlock.yaml` (`jbh-alert-pg-deadlock`) | At least one deadlock in 5 minutes | 0s | OK |

The files hold no contact point, no e-mail address and no secret.

## Where the metrics come from

Locally, Grafana Alloy (`jbh-alloy`) scrapes every endpoint below every 30 seconds and sends the samples to the local Prometheus
(remote write, so metric names stay as the services expose them). Its config is in `alloy/` (`local.alloy` and `modules/`).
Production is not built yet.

| Source | Endpoint (private, never public) | Tags |
|--------|----------------------------------|------|
| `jbh-personal-finance` | `:7777/q/metrics` | `service=jbh-personal-finance`, `env` |
| `jbh-notification` | `:7778/q/metrics` | `service=jbh-notification`, `env` |
| `jbh-iam` | `:9999/actuator/prometheus` | `service=jbh-iam`, `env` |
| `jbh-gateway` | `:8080/actuator/prometheus` | `service=jbh-gateway` (added by Alloy) |
| Postgres (`jbh-postgres`) | Alloy's built-in Postgres exporter, role `jbh_monitor`, with `pg_stat_statements` | `service=jbh-postgres` |

Caddy and the gateway forward only `/jbh-api/...`, so these endpoints are reachable only on a private network.
Traces and logs do not come from a scrape: the services push them over OTLP to Alloy (`localhost:14317` from the IDE).
How to run it on your machine: [`../LOCAL.md`](../LOCAL.md).

## Series budget

The free Grafana Cloud plan allows 10,000 active series for everything. The target is 6,000 or less.
Locally the limit does not bind, but the same budget keeps the config honest. Numbers are estimates until you count them:
`curl -s <metrics-url> | grep -vc '^#'`. Update the table when you do.

| Source | Estimate | Note |
|--------|---------:|------|
| `jbh-iam` | 1,000 | JVM, Tomcat/Hikari, HTTP histograms |
| `jbh-gateway` | 700 typical, up to 1,400 worst case | JVM, Netty, route and HTTP metrics. Target: 1,500 or less. Real count: `curl -s localhost:8080/actuator/prometheus \| grep -vc '^#'` |
| `jbh-personal-finance` | 1,200 | JVM, Agroal, HTTP histograms (11 buckets) per endpoint |
| `jbh-notification` | 600 | JVM, Agroal, few endpoints |
| Postgres, default collectors | 350 | database `postgres` only |
| Postgres `stat_statements` | 500 | about 100 statements x 5 counters |
| Alloy itself | 0 | its own metrics are not scraped |
| **Total (local)** | **4,350 typical, 5,050 worst case** | Both below the 6,000 target |

If the real total passes 6,000, first lower the number of `pg_stat_statements` rows. Production adds VPS host metrics (JBH-84).
Label rule: never put a user id, email, IP or raw path in a metric label.

## Import a dashboard

Import is by hand. There is no script and no make target. The steps are the same in the local LGTM (http://localhost:3000) and in Grafana Cloud.

1. Grafana → **Dashboards** → **New** → **Import**.
2. Click **Upload dashboard JSON file** and pick a file from `grafana/`.
3. Pick the **Prometheus** data source in the `datasource` field (and **Tempo** or **Loki** where the form asks). Pick a folder. Click **Import**.
4. The same `uid` replaces the old dashboard.

To change a dashboard: edit it in Grafana, then **Export** → **Export as JSON** (no "external sharing"),
and replace the file here. Keep `uid` the same, so the import updates the old one.
Check, for each panel, that the data is there: [`VERIFY.md`](VERIFY.md), scenario 1. How to build a dashboard: [`GUIDE.md`](GUIDE.md), part 5.

## Add an alert rule

The Grafana UI cannot import the files in `alerts/`. It imports only Prometheus YAML rule files. So you create each rule by hand from its file.
The file format stays, so JBH-84 can provision the files. Do these steps for each of the 7 files.

1. Grafana → **Alerting** → **Alert rules** → **New alert rule**.
2. **Name** = `title` of the file.
3. **Query A**: pick the data source of the file (`prometheus` or `loki`) and paste `expr` of the file.
4. Add the expressions of the file: **Reduce** (function `Last`, input A) as B, then **Threshold** (input B, the condition and value of the file) as C. Set C as the alert condition.
5. **Folder** = `JBH`. **Evaluation group** = `name` of the file, interval `1m`.
6. **Pending period** = `for` of the file.
7. **Configure no data and error handling**: set **Alert state if no data** = `noDataState` of the file. Keep **Alert state if execution error** = `Error`.
8. **Annotations**: add `summary`, `description` and `what_to_check_first` with the text of the file.
9. **Labels**: add the labels of the file (`severity`, `service`).
10. **Save rule and exit**. After 2 minutes the state must be **Normal**.

To test a rule, make it fire on purpose, then undo: [`GUIDE.md`](GUIDE.md), part 6, and [`VERIFY.md`](VERIFY.md), scenarios 3 and 4.

## Hand-over to JBH-84

Notes for the person who builds the production setup (Grafana Cloud, Alloy on the VPS).

1. **`JBH_SERVICE_VERSION`.** A new env var for every service in `compose.yaml`. It sets the resource attribute `service.version`. Default `unknown`.
   Set it to the git SHA of the image tag.
2. **CSP.** None exists today: `jbh-app/src/index.html`, the `jbh-app` `deploy/Caddyfile` and `jbh.caddy` set no `Content-Security-Policy`.
   If JBH-84 adds one, `connect-src` must allow the Faro collector host: the Grafana Cloud Faro URL in production, `http://localhost:12347` locally.
3. **Data source uids.** The files in `alerts/` use the uids `prometheus` and `loki`. In Grafana Cloud, use the uids of its data sources (or give the new data sources the same uids).
4. **Alert work that is left.** The e-mail contact point, the VPS host rules (disk, memory), the Grafana Cloud quota rule, the alert tests, and alert provisioning in Grafana Cloud.
