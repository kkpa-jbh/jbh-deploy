#!/bin/sh
# Prepares an existing local Postgres for Grafana Alloy: checks shared_preload_libraries, then runs
# initdb/sql/pg-monitor.sql (role jbh_monitor, pg_monitor, pg_stat_statements).
# Called by `make local-pg-monitor`, or by hand from this folder.
# Env: PG_ADMIN_URL (default: the Mac Postgres, no password in it), JBH_PG_MONITOR_PASSWORD (required).
# psql reads the admin password from PGPASSWORD or ~/.pgpass. This script never restarts Postgres.
set -eu

cd "$(dirname "$0")"

PG_ADMIN_URL=${PG_ADMIN_URL:-postgresql://localhost:5432/postgres}

check_psql() {
  command -v psql >/dev/null 2>&1 || {
    echo "psql not found. Install the PostgreSQL client (macOS: brew install libpq, then add it to PATH)."
    exit 1
  }
}

check_password() {
  if [ -z "${JBH_PG_MONITOR_PASSWORD:-}" ]; then
    echo "JBH_PG_MONITOR_PASSWORD is not set"
    exit 1
  fi
}

# Empty value: the only case where this script changes the setting. It needs a restart to take effect.
enable_preload() {
  psql "$PG_ADMIN_URL" -v ON_ERROR_STOP=1 -qc "ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements'" || exit 1
  echo "shared_preload_libraries was empty: set to pg_stat_statements."
  echo "Restart Postgres to load the library. Homebrew: brew services restart postgresql@16 (the command depends on how Postgres is installed)."
  echo "Then run: make local-pg-monitor again"
}

# Returns 0 when the SQL can run, 1 when the user must restart Postgres first. Exits 1 on another library list.
preload_ready() {
  # "|| exit 1": set -e is off inside a function called from "if", so a failed connection must stop here.
  raw=$(psql "$PG_ADMIN_URL" -v ON_ERROR_STOP=1 -Atqc 'SHOW shared_preload_libraries') || exit 1
  value=$(printf '%s' "$raw" | tr -d ' ')
  case ",$value," in
    *,pg_stat_statements,*) return 0 ;;
    ,,) enable_preload; return 1 ;;
  esac
  echo "shared_preload_libraries is: $value"
  echo "not changing it: add pg_stat_statements by hand"
  exit 1
}

run_sql() {
  psql "$PG_ADMIN_URL" -v ON_ERROR_STOP=1 -v pw="$JBH_PG_MONITOR_PASSWORD" -f initdb/sql/pg-monitor.sql || exit 1
  echo "jbh_monitor is ready"
}

check_psql
check_password
if preload_ready; then
  run_sql
fi
