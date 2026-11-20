# observability-guide Specification

## Purpose
TBD - created by archiving change deploy-add-dashboards-alerts-guide. Update Purpose after archive.
## Requirements
### Requirement: Beginner guide with seven parts
`observability/GUIDE.md` SHALL be written for a user who is new to Grafana (short sentences) and SHALL have these 7 parts, in this order:
1. what each part does (links to "Tech stack" in `observability/README.md`);
2. follow one request: find a trace by the `X-Trace-Id` header, read the waterfall, jump to its logs;
3. query basics with JBH examples: PromQL (rate, error rate, p95 with `histogram_quantile`), LogQL (one service, errors, by `traceId`), TraceQL (slow traces, traces with errors);
4. add a metric in a service (Quarkus and Spring Boot with Micrometer) and the label rules (series budget);
5. build a dashboard, export it as JSON, commit it here;
6. add an alert and test it;
7. local against Grafana Cloud: URLs, differences, 14-day retention.
Examples SHALL use real JBH metric names and labels.

#### Scenario: Reader follows one request
- **WHEN** a reader follows part 2 with a response header `X-Trace-Id: <id>`
- **THEN** the steps lead to Explore, Tempo, the trace id, the waterfall, and then to the logs of that trace

### Requirement: Pointer file in the leader folder
`/Users/cristianpena/cpena/sw/github/kkpa-jbh/kkpa/observability.md` SHALL exist, with 5 to 10 lines: what JBH observability is, and links to `jbh-deploy/observability/GUIDE.md` and `jbh-deploy/observability/README.md`.
It is outside the repo and is not versioned.

#### Scenario: Pointer exists
- **WHEN** the file is read
- **THEN** it has 5 to 10 lines and both links

### Requirement: Hands-on verification checklist
`observability/VERIFY.md` SHALL be a checklist the user follows on the local stack (Grafana `http://localhost:3000`), in the same plain style as `GUIDE.md` (short sentences, common words, copy-paste commands and queries).
It SHALL have these 5 scenarios, and each one SHALL give: what to do, where to look in Grafana, the exact query, what you should see, and how to undo:
1. dashboards: import each JSON by hand, pick the data source, check every panel has data, and name the panels that need traffic first and how to make it;
2. traces and spans: get a trace id from the `X-Trace-Id` response header (browser DevTools and a `curl` to the gateway on `:8080`), open it in Explore, Tempo, read the waterfall (`jbh-web`, `jbh-gateway`, `jbh-iam-service` or `jbh-personal-finance`, database), plus TraceQL for errors, slow traces and traces with 3 or more services;
3. metrics and alerts: create the alert rules by hand, check each is Normal, make one fire on purpose, see it in Alerting, Alert rules (no email locally; email is JBH-84);
4. service down: stop one service (`docker stop jbh-local-jbh-personal-finance-1` or `make local-swap s=jbh-personal-finance`), show what each signal says (gateway `503`, Consul, Prometheus `up`, the overview panel, the "service down" alert after its `for` time), then `make local-restore s=<service>` and see the recovery;
5. exceptions and errors: Loki by service and level, Tempo traces with status error, the 5xx panel, Faro errors (`app_name="jbh-web"`, `kind=exception`), one way to cause a real error, and how to go from a log line to its trace by `trace_id`.
`VERIFY.md` and `GUIDE.md` SHALL both carry a table of the name differences between data sources (IAM is `job="jbh-iam"` in Prometheus and `service_name="jbh-iam-service"` in Loki and Tempo).
`GUIDE.md` and `observability/README.md` SHALL link to `VERIFY.md`.

#### Scenario: Reader checks a service down
- **WHEN** the user follows scenario 4 and stops `jbh-personal-finance`
- **THEN** a call through the gateway answers `503`, Consul no longer lists it as passing, `up{job="jbh-personal-finance"}` is `0`, and after 5 minutes the "service down" rule is Firing

#### Scenario: Every query was run
- **WHEN** the wave ends
- **THEN** the leader has run each query of `VERIFY.md` once against the local stack (read only) and reports which ones could not run

