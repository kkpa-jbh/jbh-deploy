# grafana-alerts Specification

## Purpose
TBD - created by archiving change deploy-add-dashboards-alerts-guide. Update Purpose after archive.
## Requirements
### Requirement: Seven alert rules as code
`observability/alerts/` SHALL hold one YAML file per rule, in the Grafana alert rule file provisioning format (`apiVersion: 1`, `groups`, folder `JBH`):
`jbh-service-down.yaml` (no data or `up` = 0 for 5 min), `jbh-http-5xx-rate.yaml` (5xx above 5% for 5 min), `jbh-http-p95-latency.yaml` (p95 above 2 s for 10 min),
`jbh-jvm-heap-high.yaml` (heap above 90% of max for 10 min), `jbh-frontend-error-spike.yaml` (more than 10 Faro exceptions in 5 min, from Loki),
`jbh-postgres-connections-high.yaml` (connections above 80% of `max_connections` for 5 min), `jbh-postgres-deadlock.yaml` (any deadlock in 5 min).
Each rule SHALL have a fixed `uid`, a `condition`, the annotations `summary` and `what_to_check_first` (short, with the first dashboard and the first query to open), and the label `severity`.
No file SHALL hold a contact point, an email address or a secret.

#### Scenario: Every rule has a first check
- **WHEN** each alert file is read
- **THEN** it has a non-empty `what_to_check_first` annotation and a fixed `uid`

#### Scenario: Healthy local stack
- **WHEN** the local stack runs without faults and each rule is created in the local Grafana
- **THEN** every rule shows state Normal after two evaluations

#### Scenario: Forced firing
- **WHEN** the user lowers the threshold of one rule to a value the current data already passes
- **THEN** the rule goes to Pending, then Firing after its `for` time. The user discards the change after the test

### Requirement: Manual creation in the UI
The docs SHALL say that the Grafana UI cannot import an alert rule provisioning file (it imports only Prometheus YAML rule files),
and SHALL give the steps to create each rule by hand from its file (query, expression, threshold, `for`, annotations). The file format is kept so JBH-84 can provision the files.

#### Scenario: Reader creates a rule
- **WHEN** a reader follows `observability/README.md` "Add an alert rule"
- **THEN** the steps name Alerting, Alert rules, New alert rule, and map each field of the file to a field of the form

