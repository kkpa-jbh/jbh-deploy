# Observability

How JBH collects logs, metrics and traces, and the Grafana dashboards for the JBH services.

## Tech stack

**Status:** this is the target design of epic JBH-55. It is not all built yet.
Today only finance, notification and iam expose metrics. Traces and logs reach the local LGTM only from finance and notification.
The sub-issues JBH-56..59, 61 and 81..83 build the rest.

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

| Service | Endpoint (private, never public) | Tags |
|---------|----------------------------------|------|
| `jbh-personal-finance` | `:7777/q/metrics` | `service=jbh-personal-finance`, `env` |
| `jbh-notification` | `:7778/q/metrics` | `service=jbh-notification`, `env` |
| `jbh-iam` | `:9999/actuator/prometheus` | `service=jbh-iam`, `env` |

Caddy and the gateway forward only `/jbh-api/...`, so these endpoints are reachable only on `jbh-private`.
In production, Alloy scrapes them (JBH-56). Locally, the LGTM stack in `kkpa-docker-lab/lgtm` scrapes them.

## Import a dashboard

1. Grafana → **Dashboards** → **New** → **Import**.
2. Upload the JSON file. Pick the Prometheus data source.
3. Same steps for the local LGTM stack (http://localhost:3000) and for Grafana Cloud.

To change a dashboard: edit it in Grafana, then **Export** → **Export as JSON** (no "external sharing"),
and replace the file here. Keep `uid` the same, so the import updates the old one.
