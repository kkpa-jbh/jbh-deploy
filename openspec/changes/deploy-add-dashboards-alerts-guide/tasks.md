## Test blueprint

Not applicable. No unit tests (plan: "Unit tests: excluded"; JSON, YAML, Alloy config and Markdown only). No blueprint group. Checks: design.md "Test contract" (S1-S9, M1-M5). Nobody runs a build in this pipeline.
Rules for every task: Context7 for Grafana and Alloy syntax; follow the conventions in design.md D1 and D4; real metric names only; no HTML comments; do not touch the files listed under Non-goals in proposal.md.

## 1. Alloy: Faro service.name

Depends on: nothing.

- [ ] 1.1 `observability/alloy/local.alloy`: add `otelcol.processor.transform "faro_service"` (design.md D2) and point `otelcol.receiver.loki "faro"` output to it. Update the header or the Faro comment: one line that says why (Loki would show `unknown_service`). Check the exact OTTL syntax in the Alloy docs first.

## 2. Dashboards (four disjoint files, can run in parallel)

Depends on: nothing (names from design.md D1, D3). Use `jbh-circuit-breakers.json` as style reference. Each file: `uid`, tag `jbh`, `datasource` variable first in `templating.list`, per-panel `description`.

- [ ] 2.1 `observability/grafana/jbh-overview.json` (D3): variables `datasource`, `loki`, `env`; up, rate, 5xx, 4xx, p95, frontend errors stat, text panel, dashboard links. About 450 lines.
- [ ] 2.2 `observability/grafana/jbh-service.json` (D3): variables `datasource`, `service`, `env`, `instance`; latency, errors, JVM, GC, threads, CPU, DB pool. About 800 lines.
- [ ] 2.3 `observability/grafana/jbh-postgres.json` (D3): connections against max, transactions, locks, deadlocks, cache hit, size, top queries. About 600 lines.
- [ ] 2.4 `observability/grafana/jbh-traces.json` (D3): variables `tempo`, `datasource`; slowest, errors, 3 or more services (check `count_distinct` support), service graph, rate and failed series. About 350 lines.

## 3. Alerts (seven disjoint files, can run in parallel)

Depends on: nothing (table in design.md D4).

- [ ] 3.1 `observability/alerts/jbh-service-down.yaml`
- [ ] 3.2 `observability/alerts/jbh-http-5xx-rate.yaml`
- [ ] 3.3 `observability/alerts/jbh-http-p95-latency.yaml`
- [ ] 3.4 `observability/alerts/jbh-jvm-heap-high.yaml`
- [ ] 3.5 `observability/alerts/jbh-frontend-error-spike.yaml`
- [ ] 3.6 `observability/alerts/jbh-postgres-connections-high.yaml`
- [ ] 3.7 `observability/alerts/jbh-postgres-deadlock.yaml`

Each file: provisioning format (D4), the uid, threshold, `for`, `noDataState` from the table, annotations `summary`, `description`, `what_to_check_first`, label `severity`. About 90 lines each.

## 4. Beginner guide

Depends on: 1 (Faro `service_name="jbh-web"` in LogQL examples), 2 and 3 (file names for parts 5 and 6).

- [ ] 4.1 `observability/GUIDE.md`: 7 parts, design.md D6. Short sentences. Real JBH names. About 450 lines; say in the report that it passes 400.

## 5. Reference docs

Depends on: 2, 3, 4 (names and links).

- [ ] 5.1 `observability/README.md` (D7, D8): dashboards table, alerts table, import steps (dashboard UI import; alert rules by hand), status text, gateway series row and totals, "Hand-over to JBH-84", link to `GUIDE.md`.
- [ ] 5.2 `README.md` (D8): the `X-Trace-Id` bullet in "### 1. Frontend to gateway"; the Faro line in "Observability (local)". `LOCAL.md` (D8): pointer to the guide and dashboards, `X-Trace-Id` tip. `CLAUDE.md`: files table row. Depends on: 4 (guide name), 1.

## 6. Pointer file (leader)

Depends on: 4, 5.1.

- [ ] 6.1 `/Users/cristianpena/cpena/sw/github/kkpa-jbh/kkpa/observability.md`: 5 to 10 lines, what JBH observability is, links to `jbh-deploy/observability/GUIDE.md` and `README.md`. Written by the leader (outside the repo, not git).

## 7. Static checks

Depends on: 1-6.

- [ ] 7.1 Run S1-S9 from design.md "Test contract". The leader runs them; the user runs M1-M5 and reports.


## 8. Verification checklist (added)

Depends on: 2, 3, 4 (names of dashboards, rules and the guide), 1 (Faro name). Tasks 1-7 are unchanged.

- [ ] 8.1 `observability/VERIFY.md`: 5 scenarios with the sub-headings Do, Look, Query, You should see, Undo (design.md D9); the name table (D10); short sentences, common words, real copy-paste commands. Only the user stops or starts containers. About 400 lines; say in the report if it passes 400.
- [ ] 8.2 `observability/GUIDE.md`: link to `VERIFY.md` (end of part 2 and in part 6), and the name table (D10) in part 1 or 2; LogQL and TraceQL examples in part 3 use `jbh-iam-service`. Depends on: 4.1, 8.1.
- [ ] 8.3 `observability/grafana/jbh-traces.json`: the "3 or more services" panel uses the explicit `&&` query of D10 (not `count_distinct`) and its description says so. Depends on: 2.4.
- [ ] 8.4 `observability/README.md`: link to `VERIFY.md` in the intro and in "Import a dashboard" and "Add an alert rule". Depends on: 5.1, 8.1.
- [ ] 8.5 Static checks S10-S12 and manual check M6 (design.md "Addendum"). The leader runs S10-S12; the user runs M6. Depends on: 8.1-8.4.

Size estimate: 18 files, ~4,000 changed lines (tests and docs included; 4 dashboards ~2,200, 7 alerts ~630, GUIDE ~470, VERIFY ~400, other docs and Alloy ~330; the pointer file is outside the repo)
