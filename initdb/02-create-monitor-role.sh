#!/bin/sh
# Runs once, on the first start of jbh-postgres (empty volume), after 01-create-databases.sh.
# Creates the least-privilege role that Grafana Alloy uses to read Postgres statistics:
#   - role jbh_monitor (LOGIN, password from JBH_PG_MONITOR_PASSWORD)
#   - GRANT pg_monitor: reads statistics only, no table data
#   - pg_stat_statements in database "postgres" (the library is loaded by the compose command)
# psql escapes the password with :'pw', so it is never glued into the SQL text.
# The production compose.yaml mounts this same folder and does not pass the password. Without the
# guard below, "set -u" would fail the first start of a fresh volume. So an empty password skips the script.
# On an existing volume this script does not run: see LOCAL.md, "Existing Postgres volume".
set -eu

if [ -z "${JBH_PG_MONITOR_PASSWORD:-}" ]; then
  echo "02-create-monitor-role: skip: JBH_PG_MONITOR_PASSWORD is not set"
  exit 0
fi

psql -v ON_ERROR_STOP=1 -v pw="$JBH_PG_MONITOR_PASSWORD" --username "$POSTGRES_USER" --dbname postgres <<'SQL'
CREATE ROLE jbh_monitor LOGIN PASSWORD :'pw';
GRANT pg_monitor TO jbh_monitor;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
