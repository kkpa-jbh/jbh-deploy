# Verify the observability stack

A hands-on checklist for the local stack. Follow the 5 scenarios in order.
Each scenario has the same 5 steps: **Do**, **Look**, **Query**, **You should see**, **Undo**.
For the why, read [`GUIDE.md`](GUIDE.md). For the design, read [`README.md`](README.md).

## Before you start

1. `make lgtm up` in `kkpa-docker-lab`. Grafana is at http://localhost:3000 (user `admin`, password `admin`).
2. `make local-up` in `jbh-deploy`. Wait until `make local-ps` shows the containers healthy.
3. If you changed `observability/alloy/local.alloy`, run `make local-alloy`. Faro lines get `service_name="jbh-web"` only after this restart.
4. Open the Alloy UI http://localhost:12345. Every component must be healthy.
5. Open Consul http://localhost:8500. `jbh-iam-service`, `jbh-personal-finance`, `jbh-notification` and `API Gateway` must be green.

Where to type a query: Grafana, **Explore** (compass icon), pick the data source at the top, use **Code** mode.

### Names

The same service has different names in each data source. Use the right one in each query.

| Service | Prometheus `job` / `service` | Loki `service_name` | Tempo `resource.service.name` | Consul |
|---------|------------------------------|---------------------|-------------------------------|--------|
| IAM | `jbh-iam` | `jbh-iam-service` | `jbh-iam-service` | `jbh-iam-service` |
| Finance | `jbh-personal-finance` | `jbh-personal-finance` | `jbh-personal-finance` | `jbh-personal-finance` |
| Notification | `jbh-notification` | `jbh-notification` | `jbh-notification` | `jbh-notification` |
| Gateway | `jbh-gateway` | `jbh-gateway` | `jbh-gateway` | `API Gateway` (health check `API-Gateway`) |
| Browser (Faro) | none | `jbh-web` (after the Alloy restart) | `jbh-web` | none |

Other names:

- Containers: `jbh-local-<service>-1`. Example: `jbh-local-jbh-personal-finance-1`. Also `jbh-local-jbh-alloy-1`, `jbh-local-jbh-postgres-1`, `jbh-local-jbh-consul-1`.
- Prometheus `up` also has `integrations/postgres` (Postgres, `service="jbh-postgres"`) and `otelcol-contrib`.
- Loki labels: `service_name`, `service_namespace`, `deployment_environment_name`. The level is `detected_level` (upper case: `INFO`, `WARN`, `ERROR`).
- The trace of a log line is the structured metadata field `trace_id`.

## Scenario 1: Dashboards

**Do**

Import the 4 dashboards, one at a time.

1. Grafana, **Dashboards**, **New**, **Import**.
2. Click **Upload dashboard JSON file**. Pick one file from `observability/grafana/`: `jbh-overview.json`, `jbh-service.json`, `jbh-postgres.json`, `jbh-traces.json`.
3. In the data source field, pick **Prometheus** (and **Tempo** or **Loki** where the form asks). Click **Import**.
4. Make traffic. Open http://localhost:8100 (`ionic serve`), sign in, and open the finance pages (products, preferences).
   Then sign in once with a wrong password, to make a `4xx` (see scenario 5).
5. Wait 1 to 2 minutes. Alloy scrapes every 30 seconds.

**Look**

Open each dashboard (**Dashboards**, search `JBH`). Set the time range to **Last 15 minutes**.

| Dashboard | Panels with data at once | Panels that need traffic first |
|-----------|--------------------------|--------------------------------|
| `JBH - Overview` | Up | Request rate, 5xx rate, 4xx rate, p95 latency, Frontend errors (1h) |
| `JBH - Service detail` | Up, Heap used %, JVM heap and non-heap, GC pause, Threads, CPU, DB pool | Latency p50, p95, p99 per uri, Error rate per uri, Request rate per uri |
| `JBH - Postgres` | Postgres up, Connections %, Connections by state, Locks by mode, Database size, Cache hit ratio | Transactions per second, Top 10 queries by total time |
| `JBH - Traces` | none | Slowest traces, Traces with errors, Traces that touch 3 or more services, Service graph, Calls per second |

Notes:

- `Traces with errors` can stay empty when no error happened. That is fine.
- In `JBH - Service detail`, pick the service in the `service` variable. For `jbh-personal-finance`, the **Agroal** panel has data and **Hikari** shows "No data".
  For `jbh-iam`, it is the other way round.
- `jbh-notification` has no p95 line. It exposes no `http_server_requests_seconds_bucket` series yet.
- `Frontend errors (1h)` counts only Faro exceptions. It shows 0 or "No data" when the app has no error.

**Query**

Run these in Explore, Prometheus, to check the data behind the panels:

```
up{job=~"jbh-(gateway|iam|personal-finance|notification)"}
```

```
sum by (job) (rate(http_server_requests_seconds_count{job=~"jbh-.*",uri!~"/actuator.*|/q/.*"}[5m]))
```

```
histogram_quantile(0.95, sum by (job, le) (rate(http_server_requests_seconds_bucket{job=~"jbh-.*",uri!~"/actuator.*|/q/.*"}[5m])))
```

```
sum by (state) (pg_stat_activity_count{service="jbh-postgres"})
```

Or, from a terminal:

```
curl -s -G http://localhost:9090/api/v1/query --data-urlencode 'query=up{job=~"jbh-(gateway|iam|personal-finance|notification)"}'
```

**You should see**

- Each dashboard imports without an error. The `uid` stays (`jbh-overview`, `jbh-service`, `jbh-postgres`, `jbh-traces`).
- Overview, **Up**: 4 services, each `UP` (value 1).
- After traffic: lines for `jbh-gateway`, `jbh-iam` and `jbh-personal-finance` in request rate and p95.
- The first query returns 4 series with value `1`. The second returns one value per job that had traffic.
- Postgres: connections stay below the max line.
- Traces: the three tables list traces. The service graph shows `jbh-gateway` calling `jbh-iam-service`.

**Undo**

Delete the dashboards: **Dashboards**, tick the 4 `JBH` dashboards (not `Gateway client circuit breakers` if you want to keep it), **Delete**.
Nothing else changed. You can import them again at any time. The same `uid` replaces the old dashboard.

## Scenario 2: Traces and spans

**Do**

1. Get a trace id. Use one of these.
   - In the browser: DevTools, **Network**, click any `/jbh-api/...` call, **Response Headers**, copy `X-Trace-Id`.
   - With `curl`. A call without a token is the cheapest test:

     ```
     curl -si http://localhost:8080/jbh-api/users/userinfo
     ```

     The answer is `401`. Copy the value of `X-Trace-Id` (32 hex characters).
2. Wait 10 seconds. Tempo needs a moment.

**Look**

1. Grafana, **Explore**, data source **Tempo**.
2. Query type **TraceQL**. Paste the trace id. Press Shift+Enter.
3. Read the waterfall. The order from the browser is `jbh-web`, then `jbh-gateway`, then `jbh-iam-service` or `jbh-personal-finance`.
   A service that calls Postgres has a database span below it.
   A `curl` call starts at `jbh-gateway`: there is no `jbh-web` span.
4. Then run the three TraceQL queries below, one at a time.

**Query**

Find one trace by id, in a terminal (replace the id):

```
curl -s http://admin:admin@localhost:3000/api/datasources/proxy/uid/tempo/api/traces/<trace id> | head -c 300
```

Errors:

```
{ status = error }
```

Slow traces:

```
{ trace:rootService = "jbh-gateway" && trace:duration > 500ms }
```

Traces with 3 or more services. The local Tempo does not parse `count_distinct`, so use the explicit form:

```
{ resource.service.name = "jbh-gateway" } && { resource.service.name = "jbh-iam-service" } && { resource.service.name = "jbh-personal-finance" }
```

A trace that starts in the browser:

```
{ resource.service.name = "jbh-web" } && { resource.service.name = "jbh-gateway" } && { resource.service.name = "jbh-iam-service" }
```

**You should see**

- The `curl` answer has `HTTP/1.1 401 Unauthorized` and a line `X-Trace-Id: <32 hex characters>`.
- Tempo shows one trace with the same id. Its root is `jbh-gateway`.
- A trace from the app shows `jbh-web` first.
- `{ status = error }` lists traces only if a call failed. An empty list is fine on a healthy stack.
- The slow-trace query lists traces that took more than 500 ms. It can be empty on a fast machine.
- The `&&` queries list traces that touched all the named services.

**Undo**

Nothing to undo. These steps only read.

## Scenario 3: Metrics and alerts

**Do**

1. Create the 7 alert rules by hand. Use the steps in [`README.md`](README.md#add-an-alert-rule) for each file in `observability/alerts/`.
2. Wait 2 minutes.
3. Make one rule fire, without stopping anything. Use `jbh-jvm-heap-high`, because its query always has data:
   1. **Alerting**, **Alert rules**, open `JBH JVM heap above 90%`, **Edit**.
   2. Change the threshold from `IS ABOVE 0.9` to `IS ABOVE 0`. Every running service uses some heap, so it passes.
   3. Set the pending period to `0s`. Click **Save rule and exit**.
4. Wait one or two minutes.

Do not use a 5xx or p95 rule for this test. With no `5xx`, their query returns nothing, not `0`.
An empty result is "no data", and these rules keep **Normal** on no data. A lower threshold does not change that.

**Look**

- **Alerting**, **Alert rules**. Open the folder `JBH`.
- After step 2, all 7 rules show **Normal**.
- After step 4, `JBH JVM heap above 90%` shows **Pending**, then **Firing**. It fires once per service (one series each).
- Open the rule. The annotation `what_to_check_first` shows the first check.
- No email is sent locally. Email is JBH-84. The state in **Alert rules** is the check.

**Query**

The heap rule uses this query (heap used, as a share of the max). Explore, Prometheus:

```
sum by (job, instance) (jvm_memory_used_bytes{area="heap"}) / sum by (job, instance) (jvm_memory_max_bytes{area="heap"} > 0)
```

The 5xx rule uses this query (the share of 5xx):

```
sum by (job) (rate(http_server_requests_seconds_count{job=~"jbh-(gateway|iam|personal-finance|notification)",uri!~"/actuator.*|/q/.*",status=~"5.."}[5m])) / sum by (job) (rate(http_server_requests_seconds_count{job=~"jbh-(gateway|iam|personal-finance|notification)",uri!~"/actuator.*|/q/.*"}[5m]))
```

**You should see**

- All 7 rules **Normal** after 2 minutes. None in **Error**. The rule `JBH service down` stays Normal because the 4 `up` series are 1.
- The heap query returns one value per service, between `0` and `1` (for example `0.2`).
- The 5xx query returns nothing when no `5xx` happened. That is normal on a healthy stack.
- The edited heap rule goes **Pending**, then **Firing**.
- To see the 5xx rule fire for real, stop a service and call it (scenario 4 makes `503` answers).

**Undo**

Open the edited rule, **Edit**. Set the threshold `IS ABOVE 0.9` and the pending period `10m` from the file `jbh-jvm-heap-high.yaml`.
Save. The state returns to **Normal**. Or delete the rule and create it again from its file.

## Scenario 4: Service down

The user runs every step of this scenario. Stop one service, look at each signal, then bring it back.

**Do**

1. Check the start state. All 4 services are up:

   ```
   curl -s -G http://localhost:9090/api/v1/query --data-urlencode 'query=up{job=~"jbh-(gateway|iam|personal-finance|notification)"}'
   ```

2. Stop finance. Use one of the two commands:

   ```
   docker stop jbh-local-jbh-personal-finance-1
   ```

   ```
   make local-swap s=jbh-personal-finance
   ```

3. Call a finance path through the gateway. Use the app, or `curl` with a valid token:

   ```
   curl -si http://localhost:8080/jbh-api/finance/products -H "Authorization: Bearer <token>"
   ```

4. Wait 1 minute, then 6 minutes. Check the signals in the order below.

**Look**

In this order:

1. The gateway call in step 3 answers `503`. (Without a token, the answer is `401` and does not test this.)
2. Consul http://localhost:8500: `jbh-personal-finance` is gone or red. A terminal check:

   ```
   curl -s http://localhost:8500/v1/health/state/passing
   ```

   The list no longer holds `jbh-personal-finance`.
3. Prometheus: `up{job="jbh-personal-finance"}` is `0` within 30 seconds to 1 minute.
4. The dashboard `JBH - Overview`, panel **Up**: `jbh-personal-finance` is red (`DOWN`).
5. **Alerting**, **Alert rules**: `JBH service down` is **Pending**, then **Firing** 5 minutes after the first `0`.

**Query**

```
up{job="jbh-personal-finance"}
```

```
up{job=~"jbh-(gateway|iam|personal-finance|notification)"} < 1
```

**You should see**

- The gateway answers `503` for finance calls.
- Consul no longer lists `jbh-personal-finance` as passing.
- `up{job="jbh-personal-finance"}` is `0`. The second query returns that one series.
- The Overview panel **Up** shows the service red.
- After 5 minutes the rule `JBH service down` is **Firing**.

**Undo**

Bring the service back:

```
make local-restore s=jbh-personal-finance
```

After a plain `docker stop`, use `docker start jbh-local-jbh-personal-finance-1`.

Then check: `up{job="jbh-personal-finance"}` is `1` again, Consul shows it green, and the rule `JBH service down` returns to **Normal** after one or two evaluations.

## Scenario 5: Exceptions and errors

**Do**

Cause a real error. Use one of these.

- A wrong login. It gives `401`. Use a fake e-mail, never a real account:

  ```
  curl -si -X POST http://localhost:8080/jbh-api/auth/signin -H 'Content-Type: application/json' -d '{"usernameOrEmail":"nobody@example.com","password":"wrong"}'
  ```

  The sign-in route allows 10 requests per minute per IP. A `429` means you sent too many. Wait one minute.
- A call while a service is down (scenario 4). It gives `503`.

Copy the `X-Trace-Id` of the answer.

**Look**

1. Explore, **Loki**: errors of IAM, then errors and warnings of all JBH services.
2. Explore, **Tempo**: traces with errors.
3. Dashboard `JBH - Overview`: the panels `5xx rate` and `4xx rate`.
4. Explore, **Loki**: Faro errors from the browser.
5. From a log line to its trace: in a Loki result, open a line, copy the `trace_id` field. Go to Tempo, **TraceQL**, paste it.
6. From a trace to its logs: run the `trace_id` query below.

A service that logs nothing for the call has no line. Finance logs only when its code logs. Then use the trace.

**Query**

Loki:

```
{service_name="jbh-iam-service"} | detected_level="ERROR"
```

```
{service_name=~"jbh-.+"} | detected_level=~"ERROR|WARN"
```

```
{service_name="jbh-web"} |= "kind=exception"
```

From a trace to its logs (replace the id):

```
{service_name=~"jbh-.+"} | trace_id="<trace id>"
```

Tempo:

```
{ status = error }
```

Prometheus (the 4xx share, for the wrong login):

```
sum by (job) (rate(http_server_requests_seconds_count{status=~"4..",uri!~"/actuator.*|/q/.*"}[5m]))
```

**You should see**

- The wrong login answers `401` with an `X-Trace-Id`.
- The first Loki query shows a line only if IAM logged an `ERROR`. An empty result is fine when no error happened.
- The second query shows `WARN` lines. For example the gateway logs a `WARN` for a call without a token.
- The `trace_id` query shows the lines of that one trace.
- `{ status = error }` shows traces with an error span, when one exists.
- The Overview panels `4xx rate` (wrong login) and `5xx rate` (a stopped service) show a rise.
- The Faro query shows lines only after the Alloy restart and when the browser app sent an exception.
  Lines from before the restart are `service_name="unknown_service"` and stay so until they expire.

**Undo**

Nothing to undo. The wrong login changed no data. If you stopped a service, run the undo of scenario 4.

## Final check

When all 5 scenarios are done, the stack is back to normal:

- `up{job=~"jbh-(gateway|iam|personal-finance|notification)"}` shows 4 series with value `1`.
- The 7 rules in **Alerting**, **Alert rules** are **Normal**.
- `make local-ps` shows every container running.
