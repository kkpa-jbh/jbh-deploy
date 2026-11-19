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
`initdb/sql/pg-monitor.sql` SHALL create role `jbh_monitor` with `LOGIN` only when it does not exist, set its password with `ALTER ROLE jbh_monitor WITH LOGIN PASSWORD :'pw'`,
run `GRANT pg_monitor TO jbh_monitor`, and run `CREATE EXTENSION IF NOT EXISTS pg_stat_statements`. The password SHALL come only through the psql variable `pw`, not by building SQL text.
The file SHALL be safe to run many times, SHALL NOT contain `ALTER SYSTEM`, and SHALL sit in a subfolder of `initdb/`, so the Postgres image does not run it by itself.
`initdb/02-create-monitor-role.sh` SHALL run that file with `psql -f /docker-entrypoint-initdb.d/sql/pg-monitor.sql`, passing `JBH_PG_MONITOR_PASSWORD` as `pw`, in database `postgres`.
`jbh-postgres` in `compose.local.yaml` SHALL receive `JBH_PG_MONITOR_PASSWORD` from the env file (`:?` guard).

#### Scenario: Shared file holds the three objects
- **WHEN** `initdb/sql/pg-monitor.sql` is read
- **THEN** it holds `CREATE ROLE jbh_monitor` (inside a `\gexec` query with a `NOT EXISTS` check), `ALTER ROLE jbh_monitor`, `GRANT pg_monitor` and `CREATE EXTENSION IF NOT EXISTS pg_stat_statements`, and no `ALTER SYSTEM`

#### Scenario: SQL file is not run by the entrypoint
- **WHEN** `ls initdb/*.sql` runs
- **THEN** it finds no file

#### Scenario: First-start script uses the shared file
- **WHEN** `sh -n initdb/02-create-monitor-role.sh` runs and the file is read
- **THEN** the syntax check exits 0, the file calls `psql -f /docker-entrypoint-initdb.d/sql/pg-monitor.sql`, and no inline `CREATE ROLE` remains

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

### Requirement: Make target prepares a local Postgres for monitoring
`local.mk` SHALL define `make local-pg-monitor`. It SHALL stop with a message when `.env.local` is missing, read only `JBH_PG_MONITOR_PASSWORD` from it (no sourcing of the whole file),
run `sh ./local-pg-monitor.sh` with that value in the environment, and SHALL NOT print the value (recipe lines start with `@`, no `echo` of the value).

#### Scenario: Dry run shows the steps without a secret
- **WHEN** `make -n local-pg-monitor` runs
- **THEN** it exits 0 and shows the `.env.local` check and the call to `local-pg-monitor.sh`, with no password value

### Requirement: Script checks preload, then runs the shared SQL
`local-pg-monitor.sh` SHALL connect to `PG_ADMIN_URL` (default `postgresql://localhost:5432/postgres`) with `psql -v ON_ERROR_STOP=1`, and use `set -eu`.
It SHALL stop with a clear message and exit 1 when `psql` is missing or `JBH_PG_MONITOR_PASSWORD` is empty. It SHALL read `SHOW shared_preload_libraries` and then:
when the list holds `pg_stat_statements`, run `initdb/sql/pg-monitor.sql` with `-v pw=...`;
when it is empty, run `ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements'` (and leave `pg_stat_statements.track` at its default `top`), print the restart command and that `make local-pg-monitor` must run again, exit 0, and NOT run the SQL file;
when it holds other libraries, print the value, change nothing and exit 1.
It SHALL NEVER restart Postgres, and SHALL NOT read or write an admin password in any file.

#### Scenario: Script is valid shell with the three branches
- **WHEN** `sh -n local-pg-monitor.sh` runs and the file is read
- **THEN** the syntax check exits 0, and the file holds `command -v psql`, `SHOW shared_preload_libraries`, `ALTER SYSTEM SET shared_preload_libraries`, `-f initdb/sql/pg-monitor.sql` and `PG_ADMIN_URL`

#### Scenario: Second run changes nothing
- **WHEN** the target runs twice on a Postgres whose preload already holds `pg_stat_statements`
- **THEN** both runs exit 0 and print `jbh_monitor is ready`; the second run only sets the same password again

