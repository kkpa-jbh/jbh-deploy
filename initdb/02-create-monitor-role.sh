#!/bin/sh
# Runs once, on the first start of jbh-postgres (empty volume), after 01-create-databases.sh.
# Creates the least-privilege role that Grafana Alloy uses to read Postgres statistics.
# The SQL is shared with local-pg-monitor.sh: initdb/sql/pg-monitor.sql (a subfolder, so the
# entrypoint does not run it alone). The library is loaded by the compose command.
# The production compose.yaml mounts this same folder and does not pass the password. Without the
# guard below, "set -u" would fail the first start of a fresh volume. So an empty password skips the script.
# On an existing volume this script does not run: use `make local-pg-monitor` (see LOCAL.md).
set -eu

if [ -z "${JBH_PG_MONITOR_PASSWORD:-}" ]; then
  echo "02-create-monitor-role: skip: JBH_PG_MONITOR_PASSWORD is not set"
  exit 0
fi

psql -v ON_ERROR_STOP=1 -v pw="$JBH_PG_MONITOR_PASSWORD" --username "$POSTGRES_USER" --dbname postgres \
  -f /docker-entrypoint-initdb.d/sql/pg-monitor.sql
