## Context

JBH-55 section 8 (sub-issue JBH-61), local first. Services push OTLP to Alloy; Alloy scrapes metrics and sends all to the local LGTM
(Grafana 12.3.0, Prometheus `:9090`, uids `prometheus`, `loki`, `tempo`). Production is JBH-84.
Everything here is JSON, YAML, Alloy config and Markdown. No code, no database, no unit tests.

Facts read from the running local stack (2026-11-20, read only):

- `up` has one series per backend with `job` = `jbh-iam`, `jbh-gateway`, `jbh-personal-finance`, `jbh-notification`, and a `service` label with the same value. Postgres has `service="jbh-postgres"` (its `job` is `integrations/postgres`).
- `http_server_requests_seconds_{count,sum,bucket}` exist for gateway, iam, finance, with labels `job`, `service`, `env`, `method`, `outcome`, `status`, `uri` (gateway and iam also `error`, `exception`; finance has no `error`). `le` values: `0.005 ... 10.0, +Inf`. `jbh-notification` has no bucket series yet. Actuator URIs appear as `uri`.
- `jvm_memory_{used,max,committed}_bytes{area,id}`: heap pools differ (`G1 Eden Space`, `G1 Old Gen`, `Tenured Gen`...). Some pools have max `-1`.
- Pools: `agroal_*` (finance, notification), `hikaricp_connections_*` (iam).
- Postgres: `pg_stat_activity_count`, `pg_settings_max_connections`, `pg_stat_database_{xact_commit,xact_rollback,deadlocks,blks_hit,blks_read}`, `pg_locks_count`, `pg_database_size_bytes`, `pg_stat_statements_{seconds_total,calls_total,rows_total}{datname,queryid,user}`.
- Service graph: `traces_service_graph_request_total{client,server}`, `traces_service_graph_request_failed_total`; `server` for IAM is `jbh-iam-service`.
- Faro logs in Loki: logfmt body (`kind=event ... traceID=... app_name=jbh-web ...`), `service_name="unknown_service"`.
- Quirks: the `service` label also shows `jbh-iam-service` (OTLP/trace side) and `env` shows both `dev` and `local` for IAM over time.

Deviations from the plan, found with Context7 (Grafana, Alloy docs):

1. The plan says "Grafana alert rule export format". The Grafana UI imports only Prometheus YAML rule files, not provisioning files. So alert files are created by hand in the UI (D5).
2. Alloy docs show `resource.attributes[...]` and `log.body` path syntax in `otelcol.processor.transform`; the existing `otlp.alloy` uses the older `attributes[...]` in resource context. Both work in Alloy v1.22.0; the new Faro statement uses the log context with the new syntax (D2).

## Decisions

### D1. Dashboard conventions

Same style as `jbh-circuit-breakers.json`: `schemaVersion` 39, `refresh` `30s`, `time` `now-6h`, `graphTooltip` 1, `editable` true, tags include `jbh`.
`uid` = file name without `.json`: `jbh-overview`, `jbh-service`, `jbh-postgres`, `jbh-traces`.
Variables: `datasource` (type `datasource`, query `prometheus`); the traces dashboard adds `tempo` (query `tempo`), the overview adds `loki` (query `loki`).
Every panel and query variable uses `{"type": ..., "uid": "${datasource}"}` (or `${tempo}`, `${loki}`). No fixed uid. This is what makes one file work in the local LGTM and in Grafana Cloud.
Why not `__inputs` (the "export for sharing" form): it adds a prompt at import and changes on each export. The plain variable needs no prompt.

The service key is the **`job`** label, not `service`. Reason: `service` has the extra value `jbh-iam-service` from the trace side, `job` has exactly the four backends. Filter: `job=~"jbh-(gateway|iam|personal-finance|notification)"` (Postgres uses `service="jbh-postgres"`).
`env` variable (`label_values(up, env)`, All = `.*`) only where the metric has it; none on the Postgres dashboard. Both `dev` and `local` values show up: "All" is the default, so no data is hidden.
HTTP queries drop actuator and Quarkus management URIs: `uri!~"/actuator.*|/q/.*"`, so scrapes and health checks do not count as traffic.
Common PromQL (written once here, reused in dashboards and alerts):

| Name | Expression |
|------|------------|
| rate | `sum by (job) (rate(http_server_requests_seconds_count{<f>}[$__rate_interval]))` |
| 5xx % | `sum by (job) (rate(...{<f>,status=~"5.."}[..])) / sum by (job) (rate(...{<f>}[..]))` |
| 4xx % | same with `status=~"4.."` |
| p95 | `histogram_quantile(0.95, sum by (job, le) (rate(http_server_requests_seconds_bucket{<f>}[$__rate_interval])))` |
| heap % | `sum by (job) (jvm_memory_used_bytes{area="heap"}) / sum by (job) (jvm_memory_max_bytes{area="heap"} > 0)` |

`<f>` = `job=~"$service", env=~"$env", uri!~"/actuator.*|/q/.*"`. Heap max sums only pools with max above 0 (`-1` means "no limit" and would break the ratio). To confirm on the real data in the manual check M2.

### D2. Faro `service.name`

Problem: `faro.receiver` -> `otelcol.receiver.loki "faro"` -> OTLP. A Loki log entry has no resource `service.name`, so Loki sets `unknown_service`. The line body already holds `app_name=jbh-web`.
Choice: `otelcol.processor.transform "faro_service"` (log context) between the receiver and the exporter. It exists already in `jbh.otlp` (same component, same `error_mode = "ignore"`).

```alloy
otelcol.processor.transform "faro_service" {
  error_mode = "ignore"

  log_statements {
    context    = "log"
    statements = [
      "set(resource.attributes[\"service.name\"], ExtractPatterns(log.body.string, \"app_name=(?P<app>[^ ]+)\")[\"app\"]) where IsMatch(log.body.string, \"app_name=\")",
    ]
  }

  output {
    logs = [otelcol.exporter.otlp.lgtm.input]
  }
}
```

`otelcol.receiver.loki.faro` output changes to `otelcol.processor.transform.faro_service.input`. The Faro traces path (`faro.receiver` -> exporter) is not touched: the Faro SDK already sets `service.name` on spans.
Rejected:
- `otelcol.processor.attributes`: it works on log attributes, not on the resource, and cannot read the body.
- A `loki.process` stage before `otelcol.receiver.loki` (`stage.static_labels`): labels become log attributes, not resource attributes; Loki would still say `unknown_service`.
- Fixed `"jbh-web"` string: simpler, but the value would not follow `app_name`, which the leader asked for. If the user wants fixed, it is one line.
The worker checks the exact statement against the Alloy v1.22.0 `otelcol.processor.transform` docs (Context7 `/websites/grafana_alloy`) before writing it; the contract below is what matters, not the syntax.

### D3. Dashboards: panel plan

`jbh-overview.json` (uses `datasource`, `loki`, `env`): row of stat "Up" per job (`up{job=~...}`, value mapping 1 = UP green, 0 = DOWN red); time series request rate per job; 5xx % per job; 4xx % per job; p95 per job; stat "Frontend errors (1h)" from Loki
`sum(count_over_time({service_name="jbh-web"} |= "kind=exception" [1h]))`; text panel "Frontend" (markdown: locally Explore, Loki, `{service_name="jbh-web"}`; production Grafana Cloud Frontend Observability, link to its docs); dashboard `links`: type `dashboards` with tag `jbh`, and a `link` to Tempo Explore (`/explore?...datasource=tempo`).
`jbh-service.json` (variables `datasource`, `service` = `label_values(up{job=~"jbh-.*"}, job)` single value, `env`, `instance`): p50/p95/p99 per `uri` (three queries on one panel, or three panels); error rate per `uri` (5xx and 4xx); heap and non-heap used against max (`area` label); GC pause (`rate(jvm_gc_pause_seconds_sum[..])` and max); threads (`jvm_threads_live_threads`, `jvm_threads_daemon_threads`); CPU (`process_cpu_usage`, `system_cpu_usage`); DB pool: Agroal (`agroal_active_count`, `agroal_available_count`, `agroal_awaiting_count`) and Hikari (`hikaricp_connections_active`, `_idle`, `_pending`, `_max`). A panel with no series shows "No data": expected for the pool that the picked service does not use.
`jbh-postgres.json` (variable `datasource` only): connections by `state` against `pg_settings_max_connections` (threshold line); connections % stat; transactions per second (`xact_commit`, `xact_rollback`); locks by `mode`; deadlocks (`increase(pg_stat_database_deadlocks[$__range])`); cache hit ratio `sum(blks_hit) / (sum(blks_hit) + sum(blks_read))`; database size by `datname`; top queries table: `topk(10, sum by (datname, user, queryid) (increase(pg_stat_statements_seconds_total[$__range])))` as table, plus calls. Labels `queryid` is a number; no query text.
`jbh-traces.json` (variables `tempo`, `datasource`): Tempo table panels with `queryType: traceql`, `tableType: traces`, `limit: 20`:
slowest: `{ trace:rootService = "jbh-gateway" && trace:duration > 500ms }`; errors: `{ status = error }`; 3 or more services: `{ } | count_distinct(resource.service.name) >= 3`. A node graph panel with `queryType: serviceMap`; time series for `sum by (client, server) (rate(traces_service_graph_request_total[$__rate_interval]))` and the failed total.
The `count_distinct` function exists only in newer Tempo. The worker checks the TraceQL docs (Context7 `/grafana/tempo` or `/websites/grafana`) for the Tempo in `grafana/otel-lgtm:0.12.0`. If it is missing: use the span-set form `{ resource.service.name = "jbh-gateway" } && { resource.service.name = "jbh-iam-service" } && { resource.service.name = "jbh-personal-finance" }` and say so in the panel description.
Panel `id` values are unique per file. Each panel has a short `description` that says what it shows and what is normal.

### D4. Alert files

One file per rule in `observability/alerts/`, YAML, provisioning format:

```yaml
apiVersion: 1
groups:
  - orgId: 1
    name: jbh-<topic>
    folder: JBH
    interval: 1m
    rules:
      - uid: jbh-<rule-name>
        title: ...
        condition: C
        data: [A (query, relativeTimeRange 600s, datasourceUid prometheus), B (reduce, last), C (threshold)]
        noDataState: OK | Alerting
        execErrState: Error
        for: 5m
        annotations: { summary, description, what_to_check_first }
        labels: { severity: critical | warning, service: jbh }
```

Datasource uid is the local one (`prometheus`, `loki`). Grafana Cloud uses other uids: the JBH-84 hand-over says to change them (or keep the same uid when the data source is created).
One group per file keeps one rule = one file = one review. Expected values (the contract):

| File (uid) | Query A | Threshold | `for` | `noDataState` | Healthy local state |
|------------|---------|-----------|-------|---------------|---------------------|
| `jbh-service-down.yaml` (`jbh-alert-service-down`) | `up{job=~"jbh-(gateway|iam|personal-finance|notification)"}` | `< 1` | 5m | Alerting | Normal (4 series at 1) |
| `jbh-http-5xx-rate.yaml` (`jbh-alert-http-5xx`) | 5xx % per job (D1), exclude actuator | `> 0.05` | 5m | OK | Normal |
| `jbh-http-p95-latency.yaml` (`jbh-alert-http-p95`) | p95 per job (D1), `[5m]` | `> 2` | 10m | OK | Normal |
| `jbh-jvm-heap-high.yaml` (`jbh-alert-heap-high`) | heap % per job, per instance | `> 0.9` | 10m | OK | Normal |
| `jbh-frontend-error-spike.yaml` (`jbh-alert-frontend-errors`) | Loki `sum(count_over_time({service_name="jbh-web"} \|= "kind=exception" [5m]))` | `> 10` | 5m | OK | Normal (needs D2) |
| `jbh-postgres-connections-high.yaml` (`jbh-alert-pg-connections`) | `sum(pg_stat_activity_count{service="jbh-postgres"}) / max(pg_settings_max_connections{service="jbh-postgres"})` | `> 0.8` | 5m | Alerting | Normal (about 0.1 or less) |
| `jbh-postgres-deadlock.yaml` (`jbh-alert-pg-deadlock`) | `sum(increase(pg_stat_database_deadlocks{service="jbh-postgres"}[5m]))` | `> 0` | 0s | OK | Normal (0) |

Why `noDataState` differs: "service down" and "Postgres connections" must page when the metric disappears (a dead scrape is the fault). The rest have no traffic when idle, so "no data" is fine.
5xx and p95 divide or take quantiles of rates: with no traffic the result is NaN or empty, which compares false, so the rule stays Normal.
`what_to_check_first` is one to three short lines, for example for service down: "Alloy UI http://localhost:12345 (scrape target health), then `make local-ps` and `make local-logs s=<service>`; dashboard `jbh-overview`."
The `service-down` rule ignores `jbh-postgres`: Postgres has its own `pg_up` view in the Postgres dashboard.

### D5. Import is by hand (user decision)

No script, make target or API call. Dashboards: **Dashboards, New, Import, Upload JSON file**, pick the data source in the `datasource` field (no `__inputs`, so the form only asks the folder). Same `uid` = import replaces the old one.
Alert rules: current docs (Grafana 12.x) say the UI can import only Prometheus YAML rule files and rules from a ruler-enabled data source; it **cannot** import a provisioning file. So the README and GUIDE give the steps to create each rule from its file:
Alerting, Alert rules, New alert rule; name = `title`; query A = the `expr`; add reduce (Last) and threshold per the table; folder `JBH`; evaluation group = `name` with interval 1m; pending period = `for`; "Configure no data and error handling" = `noDataState`; annotations = the three fields; labels.
Rejected: Prometheus YAML import (loses the `what_to_check_first` annotation format and is not the format JBH-84 will provision). Rejected: Grafana API script (user decision: manual only).
Not importable in Grafana Cloud the same way: the same steps work there.

### D6. GUIDE.md

One file, 7 headings with the numbers of the plan. Short sentences. Real JBH names (`http_server_requests_seconds_bucket`, `job`, `traceId`, `X-Trace-Id`, `service_name="jbh-web"`).
Part 2 uses a concrete path: `curl -i http://localhost:8080/jbh-api/auth/...` shows `X-Trace-Id`; Explore, Tempo, "TraceQL" or "Search" tab, paste the id; waterfall; "Logs for this span" button (Tempo to Loki link in the otel-lgtm image) or Loki `{service_name=~".+"} |= "<traceId>"`.
Part 4: Quarkus (`MeterRegistry`, `@Counted`, `Timer`), Spring Boot (`MeterRegistry`, `Counter.builder`), label rules from `observability/README.md` (no user id, email, IP, raw path), series cost estimate.
Part 6: create a rule, then test by editing the threshold to fire (M4), then discard. Part 7 table: local `http://localhost:3000`, Grafana Cloud `https://<stack>.grafana.net` (JBH-84), Mimir/Prometheus, 14-day retention in Cloud, data source uids differ.
GUIDE.md will be near or over 400 lines; the report says so. Splitting is not planned: one guide file is what the plan asks for.

### D7. JBH-84 hand-over notes live in `observability/README.md`

New section "Hand-over to JBH-84". Reason: it is a living file in the repo, read by whoever starts JBH-84; archived `design.md` files are frozen and hard to find. Items:
1. `JBH_SERVICE_VERSION` (resource attribute `service.version`, default `unknown`): new env var for every service in `compose.yaml`; the git SHA of the image tag.
2. CSP: none today. `jbh-app/src/index.html`, `jbh-app` `deploy/Caddyfile` and `jbh.caddy` set no `Content-Security-Policy`. If JBH-84 adds one, `connect-src` must allow the Faro collector host (the Grafana Cloud Faro URL in production, `http://localhost:12347` locally).
3. Alert files use data source uids `prometheus` and `loki`; in Grafana Cloud use the uids of its data sources.
4. Remaining alert work: email contact point, VPS host rules, quota rule, alert tests.

### D8. Doc edits

- `README.md`: bullet in "### 1. Frontend to gateway" (text from the plan). In "Observability (local)": one sentence: "The browser (`jbh-app`, Faro) sends to the Alloy `faro.receiver` on port `12347` (`http://localhost:12347`)." The "Production" section is not touched. System map rule: this is a port in the local stack, so `README.md` changes in the same task.
- `observability/README.md`: "Dashboards" table gets 4 rows; new "Alerts" table (7 rows, file, fires when); "Import a dashboard" (fix: the plan section is by hand, `datasource` pick); new "Add an alert rule"; "Status" text updated ("Dashboards and alerts come with JBH-61" becomes done); series budget row for the gateway: `700 typical, up to 1,400 worst case (target 1,500 or less)`, total line "4,350 typical, 5,050 worst case, below 6,000", real count command `curl -s localhost:8080/actuator/prometheus | grep -vc '^#'`; "Hand-over to JBH-84" (D7); link to `GUIDE.md`.
- `LOCAL.md`: in "Observability" one step: dashboards and guide pointers (`observability/GUIDE.md`, `observability/README.md` import steps) and the tip that a gateway response header `X-Trace-Id` finds the trace. The Faro port row already exists. Nothing else changes.
- `CLAUDE.md`: files table row: `observability/grafana/`, `observability/alerts/`, `observability/GUIDE.md`.

## Responsibilities

- `observability/grafana/jbh-overview.json`: the per-service health view; changes when the service list or the health questions change (the person who runs the system).
- `observability/grafana/jbh-service.json`: one service in depth (latency, errors, JVM, DB pool); changes when a service adds a metric.
- `observability/grafana/jbh-postgres.json`: Postgres health and top queries; changes with the Postgres exporter collectors.
- `observability/grafana/jbh-traces.json`: Tempo trace views and the service graph; changes with TraceQL support or new services.
- `observability/grafana/jbh-circuit-breakers.json`: unchanged.
- `observability/alerts/jbh-*.yaml` (7): one alert rule each; changes with its threshold or its first-check note (the operator on call).
- `observability/GUIDE.md`: how to learn and use the stack; changes when a UI step or example changes.
- `observability/README.md`: reference (design, sources, budget, import, alert list, hand-over to JBH-84); changes when a file is added or the setup changes.
- `observability/alloy/local.alloy`: local pipeline wiring; this change adds only the Faro `service.name` step.
- `README.md`, `LOCAL.md`, `CLAUDE.md`: system map, local how-to, file index; each gets only the lines named in D8.
- `/Users/cristianpena/cpena/sw/github/kkpa-jbh/kkpa/observability.md`: pointer, outside git, written by the leader.

## Concurrency

none. Static files only. A dashboard import and a rule creation are one manual action by one user. Two imports of the same `uid` replace each other by design (last wins).

## Database

none. No table, column, index, migration or view.

## Test contract

No unit tests (plan: "Unit tests: excluded"; the change has no code). No test blueprint. Checks are static or manual; the user runs them.

### Static checks (the user runs them)

| Id | Command | Expected |
|----|---------|----------|
| S1 | `for f in observability/grafana/*.json; do python3 -m json.tool "$f" > /dev/null \|\| echo "BAD $f"; done` | no `BAD` line |
| S2 | `grep -h '"uid"' observability/grafana/jbh-*.json \| grep -E '"uid": "(prometheus\|loki\|tempo)"'` | no match |
| S3 | `python3 -I -c "import json,glob;print(sorted((json.load(open(f))['uid']) for f in glob.glob('observability/grafana/jbh-*.json')))"` | `['jbh-circuit-breakers', 'jbh-overview', 'jbh-postgres', 'jbh-service', 'jbh-traces']` |
| S4 | the same script: first `templating.list` item of each new file | `name == "datasource"`, `type == "datasource"` |
| S5 | `python3 -c "import yaml,glob;[yaml.safe_load(open(f)) for f in glob.glob('observability/alerts/*.yaml')]"` (needs PyYAML; else read the files) | exit 0; 7 files; each rule has `uid`, `condition`, `annotations.what_to_check_first` |
| S6 | `grep -c "faro_service" observability/alloy/local.alloy` | at least 2 (the component and the output reference) |
| S7 | `docker compose --env-file .env.example -f compose.yaml config -q && docker compose --env-file .env.local.example -f compose.local.yaml config -q` (the `Complexity-Check`) | exit 0 (files unchanged) |
| S8 | `test -f /Users/cristianpena/cpena/sw/github/kkpa-jbh/kkpa/observability.md && wc -l < /Users/cristianpena/cpena/sw/github/kkpa-jbh/kkpa/observability.md` | file exists, 5 to 10 lines |
| S9 | `git status --short` | no change in `compose.yaml`, `compose.local.yaml`, `.env.example`, `DEPLOY.md`, `Makefile`, `ci-deploy.sh` |

### Manual checks (the user runs them; local LGTM up, `make local-up`, some traffic from `ionic serve`)

| Id | Step | Expected |
|----|------|----------|
| M1 | `make local-alloy`, open http://localhost:12345 | `otelcol.processor.transform.faro_service` is healthy. Use the app, then in Explore, Loki: `{service_name="jbh-web"}` returns Faro lines; `{service_name="unknown_service"}` gets no new line |
| M2 | Import each of the 4 JSON files (Dashboards, New, Import) | Each imports without error, keeps its `uid`, the `datasource` dropdown lists Prometheus. Overview: Up shows 4 services at 1; request rate and p95 show lines for gateway, iam, finance (notification p95: No data). Service: pick `jbh-personal-finance`, heap, GC, threads, CPU and Agroal panels have data; pick `jbh-iam`, the Hikari panel has data. Postgres: connections is below the max line; top queries table has rows. Traces: the three TraceQL tables list traces (errors table may be empty with no errors), the service graph shows `jbh-gateway` and `jbh-iam-service` |
| M3 | Create each of the 7 rules in the local Grafana (README steps), open **Alerting, Alert rules** | After 2 minutes all 7 are Normal (no Error, no Firing) |
| M4 | For each rule: edit it so it fires now (for example heap threshold `> 0`), set pending `0s`, **Save and evaluate**; then discard | The rule goes Firing. For "service down": `make local-swap s=jbh-iam`, wait 6 minutes: Firing; `make local-restore s=jbh-iam`: Normal |
| M5 | Open each alert's annotations in Alerting | `what_to_check_first` shows the note |

M2 and M3 also confirm two guesses in D1/D4: that `pg_settings_max_connections` and the finance `status` and `uri` labels exist as written. If a name is wrong, the worker corrects the file, not the check.

## Risks

- Metric names or labels differ between services (finance has no `error` label): queries use only `job`, `uri`, `status`, `method`, which all three services expose.
- `log.body.string` and `ExtractPatterns` syntax: checked in the docs by the worker; M1 proves it.
- Dashboard JSON written by hand can have a wrong panel option; Grafana ignores unknown options and shows defaults. M2 is the check.
- Dashboard JSON size: about 2,200 lines for 4 files; each stays under 900 lines.

## Addendum: VERIFY.md (appended; D1-D8 and tasks 1-7 are unchanged)

### D9. `observability/VERIFY.md`

One file, written like `GUIDE.md` (short sentences, common words). A short intro (stack up: `make lgtm up` in `kkpa-docker-lab`, `make local-up`), the name table (D10), then 5 scenarios. Every scenario uses the same 5 sub-headings: **Do**, **Look**, **Query**, **You should see**, **Undo**.
The assistant never stops or starts a container. The steps that do (scenarios 3 and 4) are written for the user. Names were read from the local stack on 2026-11-20 (read only):

- Containers: `jbh-local-jbh-iam-1`, `jbh-local-jbh-personal-finance-1`, `jbh-local-jbh-gateway-1`, `jbh-local-jbh-notification-1`, `jbh-local-jbh-alloy-1`, `jbh-local-jbh-postgres-1`, `jbh-local-jbh-consul-1`.
- Prometheus `up` jobs: `jbh-gateway`, `jbh-iam`, `jbh-personal-finance`, `jbh-notification`, `integrations/postgres`, `otelcol-contrib`.
- Loki labels: `service_name`, `service_namespace`, `deployment_environment_name`; level is `detected_level` (upper case: `INFO`, `WARN`, `ERROR`) and `severity_text`; the trace is in the structured metadata `trace_id` (and `span_id`), for example `{service_name="jbh-gateway"} | trace_id="<id>"`. Loki `service_name` values: `jbh-gateway`, `jbh-iam-service`, `jbh-notification`, `jbh-personal-finance`. Tempo `resource.service.name`: `jbh-web`, `jbh-gateway`, `jbh-iam-service`, `jbh-personal-finance`.
- Consul passing checks: `API-Gateway`, `jbh-iam-service`, `jbh-notification`, `jbh-personal-finance`. Check with `curl -s http://localhost:8500/v1/health/state/passing`.
- Gateway response header: `curl -si http://localhost:8080/jbh-api/users/userinfo` answers `401` and `X-Trace-Id: <32 hex>` (a call without a token is the simplest cheap test).

Scenario plan:

1. **Dashboards.** Import the 4 files by hand (Dashboards, New, Import, Upload JSON, pick the data source). Panel by panel table: which panels fill at once (Up, JVM, GC, threads, CPU, DB pool, Postgres connections, size, locks) and which need traffic first (request rate, 5xx, 4xx, p95, per-`uri` panels, top queries, service graph, TraceQL tables, frontend errors). Make traffic: sign in at http://localhost:8100 (`ionic serve`), open the finance pages (products, preferences), then a wrong password once for the 4xx. Wait 1 to 2 scrapes (30 s each). Undo: delete the dashboards (Dashboards, select, Delete); nothing else changed.
2. **Traces.** `X-Trace-Id` from DevTools (Network, any `/jbh-api/...` call, Response Headers) or the `curl -si` above. Explore, Tempo, query type TraceQL, paste the id (or the Search tab). Waterfall: `jbh-web` (browser) then `jbh-gateway` then `jbh-iam-service` or `jbh-personal-finance`, with DB spans when the service calls Postgres. TraceQL: errors `{ status = error }`; slow `{ trace:rootService = "jbh-gateway" && trace:duration > 500ms }`; 3 or more services (D10). Undo: nothing to undo.
3. **Metrics and alerts.** Create the 7 rules by hand (D5), check Normal after 2 minutes. Make one fire without stopping anything: edit `jbh-http-5xx-rate` to threshold `>= 0` and pending `0s`, **Save and evaluate**, see Pending then Firing (needs one gateway call in the last 5 min). Prometheus check in Explore: `sum by (job) (rate(http_server_requests_seconds_count{status=~"5.."}[5m]))`. Email: not locally, JBH-84; the state change in Alerting, Alert rules is the check. Undo: discard the edit or reset the threshold from the file.
4. **Service down.** Stop `jbh-personal-finance` (`docker stop jbh-local-jbh-personal-finance-1`, or `make local-swap s=jbh-personal-finance`). In order: a finance call through the gateway returns `503` (`curl -si http://localhost:8080/jbh-api/finance/products` with a token, or the app); Consul http://localhost:8500 loses `jbh-personal-finance` (or `curl -s http://localhost:8500/v1/health/state/passing`); Prometheus `up{job="jbh-personal-finance"}` is `0` within 30 s to 1 minute; the overview "Up" panel shows it red; the "service down" rule is Pending, then Firing 5 minutes after the first `0`. Undo: `make local-restore s=jbh-personal-finance` (after a plain `docker stop`, use `docker start jbh-local-jbh-personal-finance-1`); `up` is back to `1`, the rule returns to Normal. The user runs these steps.
5. **Exceptions and errors.** Loki: `{service_name="jbh-iam-service"} | detected_level="ERROR"`, `{service_name=~"jbh-.+"} | detected_level=~"ERROR|WARN"`; Tempo `{ status = error }`; the 5xx and 4xx panels of the overview; Faro: `{service_name="jbh-web"} |= "kind=exception"` (after the D2 restart; lines from before it show `unknown_service`). Cause a real error: a wrong password at the login gives `401` (`curl -si -X POST http://localhost:8080/jbh-api/auth/signin -H 'Content-Type: application/json' -d '{"email":"nobody@example.com","password":"wrong"}'`, adjust the body to the real login DTO), or a call while a service is down gives `503`. From a log line to its trace: copy `trace_id` from the line (Loki "Fields" or the line detail), then Tempo, TraceQL tab, paste. From a trace to its logs: `{service_name=~"jbh-.+"} | trace_id="<id>"`. Note: a service that logs nothing for the call shows no line (finance logs only when it logs); then use the trace. Undo: nothing to undo.

### D10. Name mismatch and TraceQL (corrects the "worker checks" text of D3; D3 is not edited)

The same service has two names:

| Service | Prometheus `job` / `service` | Loki `service_name` | Tempo `resource.service.name` | Consul |
|---------|------------------------------|---------------------|-------------------------------|--------|
| IAM | `jbh-iam` | `jbh-iam-service` | `jbh-iam-service` | `jbh-iam-service` |
| Finance | `jbh-personal-finance` | same | same | same |
| Notification | `jbh-notification` | same | same | same |
| Gateway | `jbh-gateway` | same | same | `API-Gateway` |
| Browser | none | `jbh-web` (after D2) | `jbh-web` | none |

Effects:
- Dashboards: Prometheus parts already use `job` (D1), so no change. Loki and Tempo parts use `jbh-web`, `jbh-gateway` and `jbh-iam-service`, never `jbh-iam`. This already holds in D3 (service graph server `jbh-iam-service`, overview Loki stat `jbh-web`). The service dashboard has no Loki or Tempo query, so it needs no link by name.
- Guide and verify: GUIDE.md part 3 LogQL and TraceQL examples use `jbh-iam-service`. GUIDE.md part 1 or 2 and VERIFY.md carry the table above.
- TraceQL "3 or more services": the local Tempo (`grafana/otel-lgtm:0.12.0`) answers `count_distinct` with "parse error" (checked 2026-11-20). So the explicit form from D3 becomes the primary query, not the fallback: `{ resource.service.name = "jbh-gateway" } && { resource.service.name = "jbh-iam-service" } && { resource.service.name = "jbh-personal-finance" }`. The panel description says it is the gateway, IAM and finance case; a trace with `jbh-web` as root plus two others is also found by `{ resource.service.name = "jbh-web" } && { resource.service.name = "jbh-gateway" } && { resource.service.name = "jbh-iam-service" }`. Task 8.3 applies this to `jbh-traces.json`.
- Checked read only on 2026-11-20: `{ status = error }`, the `&&` form with three services, `{ trace:rootService = "jbh-gateway" && trace:duration > 500ms }` and `{ resource.service.name = "jbh-web" }` all return traces. Loki `{service_name="jbh-iam-service"} | detected_level="ERROR"` is valid (0 lines when no error happened). Old Faro lines are still `unknown_service` (pre D2).

### Responsibilities (added)

- `observability/VERIFY.md`: the hands-on proof that the stack works (5 scenarios with commands); changes when a query, a name or a UI step changes (the person who verifies the setup). It repeats no explanation: it links to `GUIDE.md` for the why.

### Test contract (added)

| Id | Step | Expected |
|----|------|----------|
| S10 | `grep -c '^## Scenario' observability/VERIFY.md` and `grep -c 'VERIFY.md' observability/GUIDE.md observability/README.md` | 5, and at least 1 in each of the two files |
| S11 | `grep -c -E '^\*\*(Do|Look|Query|You should see|Undo)' observability/VERIFY.md` | 25 (5 scenarios x 5 sub-headings) |
| S12 | The leader runs every query and command of `VERIFY.md` that is read only (PromQL through `http://localhost:9090/api/v1/query`, LogQL and TraceQL through the Grafana proxy, `curl` to the gateway, Consul) | each returns the result the file says, or the leader lists it as "could not run" with the reason (needs a stopped service, a browser, a UI click, or Faro traffic). The assistant never stops or starts a container |
| M6 | The user follows `VERIFY.md` scenarios 1 to 5 in order | each "You should see" matches; each "Undo" returns the stack to normal (4 services up, 7 rules Normal) |
