## ADDED Requirements

### Requirement: Dashboards are files with a fixed uid and a data source variable
`observability/grafana/` SHALL hold `jbh-overview.json`, `jbh-service.json`, `jbh-postgres.json`, `jbh-traces.json` and the unchanged `jbh-circuit-breakers.json`.
Each new file SHALL be valid JSON, SHALL have the fixed `uid` equal to its file name without `.json`, the tag `jbh`, and a `templating` variable `datasource` of type `datasource`
(`prometheus`; the traces dashboard also has `tempo`, the overview also has `loki`). Every panel and every query variable SHALL point to a data source through a variable (`${datasource}`, `${tempo}`, `${loki}`), never to a fixed data source uid.
Each file SHALL be importable with **Dashboards, New, Import** in the Grafana UI, in the local LGTM and in Grafana Cloud.

#### Scenario: Static check of every dashboard
- **WHEN** `python3 -m json.tool` runs on each new dashboard file
- **THEN** it exits 0, and the `uid` values are `jbh-overview`, `jbh-service`, `jbh-postgres`, `jbh-traces`, all different from `jbh-circuit-breakers`

#### Scenario: No fixed data source uid
- **WHEN** a new dashboard file is searched for `"uid": "prometheus"`, `"uid": "loki"` or `"uid": "tempo"`
- **THEN** there is no match

### Requirement: Overview dashboard
`jbh-overview.json` SHALL show, per service (`job` label, services `jbh-gateway`, `jbh-iam`, `jbh-personal-finance`, `jbh-notification`): up, request rate, 5xx rate, 4xx rate and p95 latency.
It SHALL have links to the other four dashboards and to Tempo Explore, and a text panel that says where the frontend signals are (Loki locally, Grafana Cloud Frontend Observability in production).
Actuator and `/q/` endpoints SHALL NOT count in request rate, error rate or latency.

#### Scenario: Four services are up
- **WHEN** the local stack runs and the overview opens
- **THEN** the "Up" panel shows 4 services with value 1

#### Scenario: Notification has no latency series yet
- **WHEN** `jbh-notification` exposes no `http_server_requests_seconds_bucket` series
- **THEN** its p95 shows "No data" and every other panel still renders

### Requirement: Service dashboard
`jbh-service.json` SHALL have a `service` variable (the `job` label) and show: p50, p95 and p99 per `uri`, error rate per `uri`, JVM heap and non-heap, GC pause, threads, CPU, and the DB pool
(Agroal for the Quarkus services, Hikari for `jbh-iam`).

#### Scenario: Pick a service
- **WHEN** the user selects `jbh-personal-finance`
- **THEN** all panels filter by `job="jbh-personal-finance"` and the DB pool panel shows Agroal series

### Requirement: Postgres dashboard
`jbh-postgres.json` SHALL show connections against `pg_settings_max_connections`, transactions, locks, deadlocks, cache hit ratio, database size, and the top queries by total time from `pg_stat_statements_seconds_total`.
It SHALL filter by `service="jbh-postgres"` and SHALL NOT show query text (it is not exported).

#### Scenario: Top queries
- **WHEN** the top queries table renders
- **THEN** rows are identified by `datname`, `user` and `queryid`, sorted by total time

### Requirement: Traces dashboard
`jbh-traces.json` SHALL have Tempo TraceQL panels: slowest traces, traces with errors, traces that touch 3 or more services, and a service graph panel.
It SHALL also show request rate and failed rate per client/server pair from `traces_service_graph_request_total` and `traces_service_graph_request_failed_total`.

#### Scenario: Service graph
- **WHEN** the local Tempo has the service graph metrics
- **THEN** the service graph shows `jbh-gateway` calling `jbh-iam-service`
