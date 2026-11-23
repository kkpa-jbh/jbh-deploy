# Observability guide

A guide for a user who is new to Grafana. It uses the real JBH names.
Short parts. Copy and paste the commands and queries.

- Design and tools: [`README.md`](README.md).
- Hands-on proof that the stack works: [`VERIFY.md`](VERIFY.md).
- Run the local stack: [`../LOCAL.md`](../LOCAL.md).

Before you start, run the local stack:

1. `make lgtm up` in `kkpa-docker-lab`. Grafana is at http://localhost:3000 (user `admin`, password `admin`).
2. `make local-up` in `jbh-deploy`. It starts the services and Alloy.
3. `ionic serve` in `jbh-app`, then sign in at http://localhost:8100 and click around. This makes traffic.

## 1. What each part does

Read the "Tech stack" section of [`README.md`](README.md#tech-stack) first. Here is the short version.

| Part | What it does | Where to look |
|------|--------------|---------------|
| Micrometer, OpenTelemetry SDK, Faro | Create the data inside the apps | Nowhere. They only create data |
| Alloy | Collects the data and sends it on | http://localhost:12345 (every component must be healthy) |
| Prometheus | Stores metrics (numbers over time) | Grafana, Explore, data source **Prometheus** |
| Loki | Stores logs | Grafana, Explore, data source **Loki** |
| Tempo | Stores traces (one request across services) | Grafana, Explore, data source **Tempo** |
| Grafana | Shows all of it. It stores nothing | http://localhost:3000 |

Three kinds of data answer three questions:

- **Metrics:** is something wrong? How much? Since when?
- **Traces:** where in the chain did the time or the error go?
- **Logs:** what did the code say at that moment?

### The same service has different names

Each data source has its own name for a service. This is the most common reason for an empty query.
Use this table.

| Service | Prometheus `job` / `service` | Loki `service_name` | Tempo `resource.service.name` | Consul |
|---------|------------------------------|---------------------|-------------------------------|--------|
| IAM | `jbh-iam` | `jbh-iam-service` | `jbh-iam-service` | `jbh-iam-service` |
| Finance | `jbh-personal-finance` | `jbh-personal-finance` | `jbh-personal-finance` | `jbh-personal-finance` |
| Notification | `jbh-notification` | `jbh-notification` | `jbh-notification` | `jbh-notification` |
| Gateway | `jbh-gateway` | `jbh-gateway` | `jbh-gateway` | `API Gateway` |
| Browser (Faro) | none | `jbh-web` | `jbh-web` | none |

Two more facts:

- Postgres is `service="jbh-postgres"` in Prometheus. Its `job` is `integrations/postgres`.
- Faro log lines are `service_name="jbh-web"` only after the Alloy restart (`make local-alloy`). Older lines stay `unknown_service`.

## 2. Follow one request

A request gets a **trace id**. Every service adds its work to that trace.
Tempo shows the trace as a waterfall. Loki holds the log lines of the same trace.

### Step 1. Get a trace id

The gateway puts the trace id in the `X-Trace-Id` response header. It does this for every answer, also `401`, `404`, `429` and `5xx`.

Option A, with `curl`. A call without a token is the simplest test:

```
curl -si http://localhost:8080/jbh-api/users/userinfo
```

The answer is `401`. Look for the line `X-Trace-Id: <32 characters>`. Copy the value.

Option B, in the browser. Open DevTools, tab **Network**, click any `/jbh-api/...` call, then **Response Headers**. Copy `X-Trace-Id`.

### Step 2. Open the trace in Tempo

1. In Grafana, open **Explore** (compass icon, left menu).
2. Pick the data source **Tempo** at the top.
3. Pick the query type **TraceQL**.
4. Paste the trace id in the query field and press **Run query** (or Shift+Enter).

You can also use the **Search** query type, then filter by service name.
A trace that has just started needs a few seconds before it shows up. Wait 10 seconds and run it again.

### Step 3. Read the waterfall

The waterfall is a list of **spans**. A span is one piece of work, with a start and a length.

- Each row is a span. The bar shows when it started and how long it took.
- Indented rows are children. The parent waits for them.
- The colour is the service. A call from the app shows `jbh-web`, then `jbh-gateway`, then `jbh-iam-service` or `jbh-personal-finance`.
  A database call is a child span of the service that made it.
- The longest bar is the first place to look. Time inside a parent but outside its children is time the parent spent itself.
- A red mark or `error=true` on a span means that span failed. Click the row to see its attributes (status code, exception).

A `curl` without `traceparent` starts a new trace at the gateway. The root is then `jbh-gateway`, not `jbh-web`.

### Step 4. Jump to the logs of the trace

Option A. In the trace view, click a span, then the **Logs for this span** button (the Tempo to Loki link of the local LGTM).

Option B. Run a query in Loki. The trace id is stored as the structured metadata field `trace_id`:

```
{service_name=~"jbh-.+"} | trace_id="<trace id>"
```

A service that logged nothing for the call shows no line. The gateway logs a `WARN` for a call without a token, so the `curl` above works for this step.

To go the other way, from a log line to its trace: open the log line, copy the `trace_id` field, then follow Step 2.

The checklist for this part, with the expected result of each step, is in [`VERIFY.md`](VERIFY.md), scenario 2.

## 3. Query basics

Open **Explore**, pick the data source, and type the query. Use **Code** mode (right side of the query field), not **Builder**.
Set the time range at the top right. **Last 15 minutes** is a good start.

### PromQL (Prometheus, metrics)

A metric has a name and labels in braces. Example: `up{job="jbh-iam"}`.
`up` is `1` when Prometheus scrapes the service and `0` when not.

Is every service up?

```
up{job=~"jbh-(gateway|iam|personal-finance|notification)"}
```

**Request rate** (requests per second, per service). `rate(...[5m])` is the average per second over 5 minutes.
The `uri!~` part leaves out scrapes and health checks.

```
sum by (job) (rate(http_server_requests_seconds_count{job=~"jbh-.*",uri!~"/actuator.*|/q/.*"}[5m]))
```

**Error rate.** The share of requests that answered 5xx. Divide the 5xx rate by the total rate:

```
sum by (job) (rate(http_server_requests_seconds_count{job=~"jbh-.*",status=~"5..",uri!~"/actuator.*|/q/.*"}[5m]))
/
sum by (job) (rate(http_server_requests_seconds_count{job=~"jbh-.*",uri!~"/actuator.*|/q/.*"}[5m]))
```

Use `status=~"4.."` for client errors. With no traffic the result is empty. That is normal.

**p95 latency.** 95 of 100 requests were faster than this value, in seconds.
`http_server_requests_seconds_bucket` counts requests per time bucket (`le` is the upper limit of the bucket).
`histogram_quantile` turns the buckets into a quantile:

```
histogram_quantile(0.95, sum by (job, le) (rate(http_server_requests_seconds_bucket{job=~"jbh-.*",uri!~"/actuator.*|/q/.*"}[5m])))
```

`jbh-notification` has no `_bucket` series yet, so it has no p95.

**Heap used, in percent of the maximum:**

```
sum by (job) (jvm_memory_used_bytes{area="heap"}) / sum by (job) (jvm_memory_max_bytes{area="heap"} > 0)
```

Some memory pools have a max of `-1` (no limit). The `> 0` leaves them out.

### LogQL (Loki, logs)

A query starts with a stream selector in braces. Then you add filters with `|=` (contains) or `|` (field filter).

All logs of one service:

```
{service_name="jbh-iam-service"}
```

Only errors. Levels are upper case:

```
{service_name="jbh-iam-service"} | detected_level="ERROR"
```

Errors and warnings of all JBH services:

```
{service_name=~"jbh-.+"} | detected_level=~"ERROR|WARN"
```

All lines of one trace:

```
{service_name=~"jbh-.+"} | trace_id="<trace id>"
```

Text search. Frontend errors from Faro:

```
{service_name="jbh-web"} |= "kind=exception"
```

Count lines per 5 minutes (a number, so it can be a graph or an alert):

```
sum(count_over_time({service_name="jbh-web"} |= "kind=exception" [5m]))
```

### TraceQL (Tempo, traces)

A query is a filter on spans, in braces. Intrinsic fields use a colon (`trace:duration`). Resource fields use a dot (`resource.service.name`).

Slow traces. The gateway is the root and the trace took more than 500 ms:

```
{ trace:rootService = "jbh-gateway" && trace:duration > 500ms }
```

Traces with an error:

```
{ status = error }
```

All traces that touch IAM:

```
{ resource.service.name = "jbh-iam-service" }
```

Traces that touch 3 services. The local Tempo does not parse `count_distinct`, so write each service as its own span set:

```
{ resource.service.name = "jbh-gateway" } && { resource.service.name = "jbh-iam-service" } && { resource.service.name = "jbh-personal-finance" }
```

For a trace that starts in the browser, use `jbh-web`, `jbh-gateway` and `jbh-iam-service` in the same form.

More examples, with the expected result of each, are in [`VERIFY.md`](VERIFY.md).

## 4. Add a metric in a service

Every JBH backend uses Micrometer. You create a meter, and the service exposes it as a Prometheus line.
Alloy scrapes it every 30 seconds. You need no change in Alloy or in this repo.

### Quarkus (`jbh-personal-finance`, `jbh-notification`)

Inject the `MeterRegistry` (package `io.micrometer.core.instrument`):

```java
@ApplicationScoped
public class StatementImportMetrics {

    private final MeterRegistry registry;

    public StatementImportMetrics(MeterRegistry registry) {
        this.registry = registry;
    }

    public void imported(String result) {
        registry.counter("jbh_statement_import", "result", result).increment();
    }

    public Timer.Sample start() {
        return Timer.start(registry);
    }

    public void stop(Timer.Sample sample) {
        sample.stop(registry.timer("jbh_statement_import_duration"));
    }
}
```

For one method, the annotation is shorter: `@Counted(value = "jbh_statement_import", extraTags = {"result", "ok"})`
or `@Timed("jbh_statement_import_duration")` on a CDI bean method.

### Spring Boot (`jbh-iam`, `jbh-gateway`)

Inject the `MeterRegistry` in a bean:

```kotlin
@Component
class SigninMetrics(private val registry: MeterRegistry) {

    fun failed(reason: String) {
        Counter.builder("jbh_signin_failed")
            .tag("reason", reason)
            .register(registry)
            .increment()
    }
}
```

### What you see in Prometheus

Micrometer renames the meter for Prometheus:

| In code | In Prometheus |
|---------|---------------|
| counter `jbh_statement_import` | `jbh_statement_import_total` |
| timer `jbh_statement_import_duration` | `jbh_statement_import_duration_seconds_count`, `_sum`, `_max` |
| gauge `jbh_queue_size` | `jbh_queue_size` |

A timer has buckets only when you turn on percentile histograms. Do it only for a meter you plan to graph as p95.

Test it: call the code, wait one scrape (30 s), then in Explore, Prometheus, run `jbh_statement_import_total`.
Or look at the endpoint directly: `curl -s localhost:7777/q/metrics | grep jbh_statement` (Quarkus), `curl -s localhost:9999/actuator/prometheus | grep jbh_signin` (IAM).

### Label rules

Each different set of label values is one **series**. Each series costs memory and money.
The free Grafana Cloud plan allows 10,000 active series for everything. The target is 6,000 or less.

- **Never** put a user id, email, IP address or raw path in a label. One value per user means one series per user.
- Use labels with few, fixed values: `result="ok"`, `reason="bad_password"`, `method="GET"`.
- For a path, use the route template (`/users/{id}`), never the real path.
- Cost = (number of values of label 1) x (number of values of label 2) x ... Example: `result` (3 values) x `method` (4 values) = 12 series.
- A timer with histogram buckets costs about 14 series per label combination (11 buckets plus count, sum and max).

Count what a service exposes now, and compare with the budget table in [`README.md`](README.md#series-budget):

```
curl -s localhost:8080/actuator/prometheus | grep -vc '^#'
```

## 5. Build a dashboard

### Step by step

1. Grafana, **Dashboards**, **New**, **New dashboard**, **Add visualization**.
2. Pick the data source **Prometheus**.
3. Type a query in **Code** mode. Start with one from part 3.
4. Pick the visualization at the top right: **Time series** for a line, **Stat** for one number, **Table** for rows, **Gauge** for a percent.
5. Set the title, the unit (right side, **Standard options**, **Unit**) and a description.
6. Click **Back to dashboard**, then **Save dashboard**.

### Use variables, so one file works everywhere

A fixed data source breaks when you import the dashboard in Grafana Cloud, because the uid is different there.
So every JBH dashboard uses a **variable** for the data source:

1. Dashboard **Settings**, **Variables**, **Add variable**.
2. Type **Data source**, name `datasource`, type `prometheus`.
3. In each panel, pick `${datasource}` as the data source, not a named one.

A `service` variable gives you one dashboard for all services: type **Query**, query `label_values(up{job=~"jbh-.*"}, job)`.
Then use `job="$service"` in the queries. See `grafana/jbh-service.json` as an example.

### Export as JSON and commit

1. Dashboard, **Export**, **Export as JSON**.
2. Do **not** turn on "Export the dashboard to use in another instance". The plain form has no prompt at import.
3. Copy or download the JSON.
4. Save it in `observability/grafana/jbh-<name>.json`.
5. Keep the `uid`. The same `uid` makes the next import replace the old dashboard.
6. Check the file: `python3 -m json.tool observability/grafana/jbh-<name>.json > /dev/null`.
7. Commit it with git.

### The dashboards of JBH

| File | Use it to |
|------|-----------|
| `grafana/jbh-overview.json` | See at a glance which service is up, and its rate, errors and p95 |
| `grafana/jbh-service.json` | Look at one service: latency per endpoint, JVM, GC, threads, CPU, DB pool |
| `grafana/jbh-postgres.json` | Check connections, locks, deadlocks, cache and the slowest queries |
| `grafana/jbh-traces.json` | Find slow traces, traces with errors, and see the service graph |
| `grafana/jbh-circuit-breakers.json` | Check the circuit breakers of `jbh-gateway-client` |

Import steps for these files: [`README.md`](README.md#import-a-dashboard).

## 6. Add an alert

An alert rule is a query, a condition and a time. When the condition holds for the whole time, the rule fires.

### The parts of a rule

| Part | Meaning | Example (`jbh-http-5xx-rate`) |
|------|---------|-------------------------------|
| Query A | Gets the numbers | the 5xx share per `job` |
| Reduce B | Takes one value per series (Last) | last value |
| Threshold C | The condition | is above `0.05` |
| Pending period (`for`) | How long the condition must hold | 5 minutes |
| No data state | What happens when the query is empty | `OK` or `Alerting` |
| Annotations | The text in the alert | `summary`, `description`, `what_to_check_first` |
| Labels | Tags for routing | `severity=critical` |

States: **Normal** (fine), **Pending** (the condition holds, the time is not over), **Firing** (alert), **No Data**, **Error**.

### Create a rule

The Grafana UI cannot import the YAML files in `alerts/`. You create each rule by hand.
The steps are in [`README.md`](README.md#add-an-alert-rule). In short:

1. **Alerting**, **Alert rules**, **New alert rule**.
2. Name = `title` of the file. Query A = `expr` of the file. Add a reduce (Last) and a threshold, as in the file.
3. Folder `JBH`. Evaluation group = `name` of the file, interval `1m`. Pending period = `for`.
4. **Configure no data and error handling**: set the no data state from the file.
5. Annotations and labels = the three annotations and the `severity` label of the file.
6. **Save rule and exit**. After 2 minutes the state must be **Normal**.

### Test it

A rule you never saw fire is a rule you cannot trust. Make it fire on purpose, then undo:

1. Open the rule, **Edit**.
2. Lower the threshold so the current data already passes it. Example: for `jbh-jvm-heap-high`, use `> 0`.
3. Set the pending period to `0s`. Click **Save rule and exit**, then wait one evaluation (1 minute).
4. The state goes to **Pending**, then **Firing**. Open the rule: the annotation `what_to_check_first` shows.
5. **Undo:** edit the rule again, set the values from the file, save. Or delete the rule and create it again.

Locally, nothing sends an email. The state change in **Alerting**, **Alert rules** is the check.
The email contact point comes with JBH-84.

A full test with a service that stops is in [`VERIFY.md`](VERIFY.md), scenarios 3 and 4.

### The rules of JBH

| File | Fires when |
|------|-----------|
| `alerts/jbh-service-down.yaml` | `up` is 0, or has no data, for 5 min |
| `alerts/jbh-http-5xx-rate.yaml` | More than 5% of requests answer 5xx for 5 min |
| `alerts/jbh-http-p95-latency.yaml` | p95 is above 2 s for 10 min |
| `alerts/jbh-jvm-heap-high.yaml` | Heap is above 90% of the max for 10 min |
| `alerts/jbh-frontend-error-spike.yaml` | More than 10 Faro exceptions in 5 min |
| `alerts/jbh-postgres-connections-high.yaml` | Connections are above 80% of `max_connections` for 5 min |
| `alerts/jbh-postgres-deadlock.yaml` | At least one deadlock in 5 min |

## 7. Local and Grafana Cloud

The same queries and dashboards work in both. The names of the data sources differ.

| | Local (LGTM in Docker) | Grafana Cloud (production, JBH-84) |
|---|------------------------|------------------------------------|
| Grafana URL | http://localhost:3000 | `https://<stack>.grafana.net` |
| Login | `admin` / `admin` | Your Grafana Cloud account |
| Metrics store | Prometheus | Mimir (same PromQL) |
| Logs and traces | Loki and Tempo in the container | Loki and Tempo in the cloud |
| Data source uids | `prometheus`, `loki`, `tempo` | Other uids, made by Grafana Cloud |
| Who sends the data | Alloy `jbh-alloy` (`make local-up`) | Alloy on the VPS (JBH-84) |
| Browser data (Faro) | Alloy `faro.receiver`, `http://localhost:12347`; logs in Loki | Frontend Observability |
| Retention | Until you remove the container volume | 14 days |
| Alert email | None | Contact point (JBH-84) |
| Limit | None | 10,000 active series (free plan) |

What this means for you:

- Dashboards use the `datasource` variable, so import works in both. Pick the data source in the dropdown after import.
- Alert files hold the local uids `prometheus` and `loki`. In Grafana Cloud, use the uids of its data sources.
- Data older than 14 days is gone in Grafana Cloud. Do not rely on it for old problems.
- The notes for JBH-84 are in [`README.md`](README.md#hand-over-to-jbh-84).
