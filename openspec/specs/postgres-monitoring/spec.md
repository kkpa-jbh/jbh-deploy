# postgres-monitoring Specification

## Purpose
TBD - created by archiving change deploy-add-grafana-alloy. Update Purpose after archive.
## Requirements
### Requirement: Local Postgres loads pg_stat_statements
`jbh-postgres` in `compose.local.yaml` SHALL start with `-c shared_preload_libraries=pg_stat_statements -c pg_stat_statements.track=top`.

#### Scenario: Start options present
- **WHEN** `jbh-postgres` is rendered from `compose.local.yaml`
- **THEN** its command contains `shared_preload_libraries=pg_stat_statements` and `pg_stat_statements.track=top`

### Requirement: Monitor role is created on the first start
`initdb/02-create-monitor-role.sh` SHALL create role `jbh_monitor` with `LOGIN` and the password from `JBH_PG_MONITOR_PASSWORD`, run `GRANT pg_monitor TO jbh_monitor`,
and run `CREATE EXTENSION IF NOT EXISTS pg_stat_statements` in database `postgres`. It SHALL pass the password to psql as a variable, not by building SQL text.
`jbh-postgres` in `compose.local.yaml` SHALL receive `JBH_PG_MONITOR_PASSWORD` from the env file (`:?` guard).

#### Scenario: Script is valid shell and creates the three objects
- **WHEN** `sh -n initdb/02-create-monitor-role.sh` runs and the file is read
- **THEN** the syntax check exits 0, and the file holds `CREATE ROLE jbh_monitor`, `GRANT pg_monitor` and `CREATE EXTENSION IF NOT EXISTS pg_stat_statements`

### Requirement: Script skips when the password is not set
When `JBH_PG_MONITOR_PASSWORD` is empty or unset, `initdb/02-create-monitor-role.sh` SHALL print one line and `exit 0`, without running psql.
Reason: the `initdb/` folder is also mounted by the prod `compose.yaml`, which does not pass the variable, so a fresh prod volume must still start.

#### Scenario: Guard is present and runs before psql
- **WHEN** the file is read
- **THEN** a check for an empty or unset `JBH_PG_MONITOR_PASSWORD` with `exit 0` appears before the `psql` call, and `set -u` does not abort on the unset variable

### Requirement: Alloy reads Postgres with the monitor role only
The `jbh.postgres` module SHALL use `prometheus.exporter.postgres` with the default collectors plus `stat_statements`, and `local.alloy` SHALL get the DSN from `sys.env("JBH_PG_MONITOR_DSN")`.
The DSN SHALL use user `jbh_monitor` and database `postgres`.

#### Scenario: No admin credentials
- **WHEN** `jbh-alloy` is rendered from `compose.local.yaml`
- **THEN** `JBH_PG_MONITOR_DSN` starts with `postgresql://jbh_monitor:` and ends with `/postgres?sslmode=disable`, and `POSTGRES_USER` and `POSTGRES_PASSWORD` are not in its environment

