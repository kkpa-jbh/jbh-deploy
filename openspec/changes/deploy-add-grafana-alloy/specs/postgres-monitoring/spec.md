## ADDED Requirements

### Requirement: Postgres loads pg_stat_statements
`jbh-postgres` in `compose.yaml` and in `compose.local.yaml` SHALL start with `-c shared_preload_libraries=pg_stat_statements -c pg_stat_statements.track=top`.

#### Scenario: Start options present
- **WHEN** `jbh-postgres` is rendered from either compose file
- **THEN** its command contains `shared_preload_libraries=pg_stat_statements` and `pg_stat_statements.track=top`

### Requirement: Monitor role is created on the first start
`initdb/02-create-monitor-role.sh` SHALL create role `jbh_monitor` with `LOGIN` and the password from `JBH_PG_MONITOR_PASSWORD`, run `GRANT pg_monitor TO jbh_monitor`,
and run `CREATE EXTENSION IF NOT EXISTS pg_stat_statements` in database `postgres`. It SHALL pass the password to psql as a variable, not by building SQL text.
`jbh-postgres` SHALL receive `JBH_PG_MONITOR_PASSWORD` from the env file (`:?` guard) in both compose files.

#### Scenario: Script is valid shell and creates the three objects
- **WHEN** `sh -n initdb/02-create-monitor-role.sh` runs and the file is read
- **THEN** the syntax check exits 0, and the file holds `CREATE ROLE jbh_monitor`, `GRANT pg_monitor` and `CREATE EXTENSION IF NOT EXISTS pg_stat_statements`

### Requirement: Existing VPS database has a documented one-time step
`DEPLOY.md` SHALL give the one-time steps for a database that already exists: set the new `.env` variables, run the same SQL by hand, then a planned restart of `jbh-postgres`
(at a quiet time, after `make backup`), and a check with `SELECT count(*) FROM pg_stat_statements;`.

#### Scenario: Runbook order
- **WHEN** a reader follows the Postgres part of `DEPLOY.md` section 8
- **THEN** the order is: `.env` values, SQL, `make up` (planned restart), check

### Requirement: Alloy reads Postgres with the monitor role only
The `jbh.postgres` module SHALL use `prometheus.exporter.postgres` with the default collectors plus `stat_statements`, and `prod.alloy` and `local.alloy` SHALL get the DSN from `sys.env("JBH_PG_MONITOR_DSN")`.
The DSN SHALL use user `jbh_monitor` and database `postgres`.

#### Scenario: No admin credentials
- **WHEN** `jbh-alloy` is rendered from either compose file
- **THEN** `JBH_PG_MONITOR_DSN` starts with `postgresql://jbh_monitor:` and ends with `/postgres?sslmode=disable`, and `POSTGRES_USER` and `POSTGRES_PASSWORD` are not in its environment
