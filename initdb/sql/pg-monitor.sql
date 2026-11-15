-- Monitor role for Grafana Alloy: role jbh_monitor, GRANT pg_monitor, extension pg_stat_statements.
-- Called by initdb/02-create-monitor-role.sh (first start of a new volume) and by
-- local-pg-monitor.sh (existing Postgres). It sits in a subfolder so the image entrypoint does not run it alone.
-- Needs: psql -v pw=<password> --dbname postgres, as a superuser. Safe to run many times.
-- It does not set shared_preload_libraries: the compose command or the caller does that.
SELECT 'CREATE ROLE jbh_monitor LOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'jbh_monitor')
\gexec
ALTER ROLE jbh_monitor WITH LOGIN PASSWORD :'pw';
GRANT pg_monitor TO jbh_monitor;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
