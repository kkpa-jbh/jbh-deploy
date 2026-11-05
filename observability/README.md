# Observability

Grafana dashboards for the JBH services. Each JSON file here is one dashboard.

| File | Shows | Metrics from |
|------|-------|--------------|
| `grafana/jbh-circuit-breakers.json` | Circuit breakers of `jbh-gateway-client`: state, failure rate, calls, rejected calls | `resilience4j_circuitbreaker_*` |

## Where the metrics come from

| Service | Endpoint (private, never public) | Tags |
|---------|----------------------------------|------|
| `jbh-personal-finance` | `:7777/q/metrics` | `service=jbh-personal-finance`, `env` |
| `jbh-iam` | `:9999/actuator/prometheus` | `service=jbh-iam`, `env` |

Caddy and the gateway forward only `/jbh-api/...`, so these endpoints are reachable only on `jbh-private`.
In production, Alloy scrapes them (JBH-56). Locally, the LGTM stack in `kkpa-docker-lab/lgtm` scrapes them.

## Import a dashboard

1. Grafana → **Dashboards** → **New** → **Import**.
2. Upload the JSON file. Pick the Prometheus data source.
3. Same steps for the local LGTM stack (http://localhost:3000) and for Grafana Cloud.

To change a dashboard: edit it in Grafana, then **Export** → **Export as JSON** (no "external sharing"),
and replace the file here. Keep `uid` the same, so the import updates the old one.
