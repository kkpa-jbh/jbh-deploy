# Observability

How JBH collects logs, metrics and traces, and the Grafana dashboards for the JBH services.

## Tech stack

**Status:** this is the target design of epic JBH-55. It is not all built yet.
Local Alloy is in place (JBH-56): it receives OTLP, scrapes the four backends and Postgres, and feeds the local LGTM.
The services still need their own changes (JBH-57..59, 81..83), and production is JBH-84. Dashboards and alerts come with JBH-61.

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
| `grafana/jbh-circuit-breakers.json` | Circuit breakers of `jbh-gateway-client`: state, failure rate, calls, rejected calls | `resilience4j_circuitbreaker_*` |

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
| `jbh-gateway` | 700 | JVM, Netty, route and HTTP metrics |
| `jbh-personal-finance` | 1,200 | JVM, Agroal, HTTP histograms (11 buckets) per endpoint |
| `jbh-notification` | 600 | JVM, Agroal, few endpoints |
| Postgres, default collectors | 350 | database `postgres` only |
| Postgres `stat_statements` | 500 | about 100 statements x 5 counters |
| Alloy itself | 0 | its own metrics are not scraped |
| **Total (local)** | **4,350** | 1,650 below the 6,000 target |

If the real total passes 6,000, first lower the number of `pg_stat_statements` rows. Production adds VPS host metrics (JBH-84).
Label rule: never put a user id, email, IP or raw path in a metric label.

## Import a dashboard

1. Grafana → **Dashboards** → **New** → **Import**.
2. Upload the JSON file. Pick the Prometheus data source.
3. Same steps for the local LGTM stack (http://localhost:3000) and for Grafana Cloud.

To change a dashboard: edit it in Grafana, then **Export** → **Export as JSON** (no "external sharing"),
and replace the file here. Keep `uid` the same, so the import updates the old one.
