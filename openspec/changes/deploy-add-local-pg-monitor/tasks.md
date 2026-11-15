## Test blueprint

No unit tests and no integration tests in this change (shell, SQL and docs; the user excludes unit tests). No blueprint group.
Verification is static: design.md "Test contract" V1-V8 (the leader runs them), V9 optional (the user).

## 1. Shared SQL

Depends on: nothing.

- [x] 1.1 `initdb/sql/pg-monitor.sql`: header comment (what, who calls it, needs `-v pw=`, safe to repeat); `SELECT 'CREATE ROLE jbh_monitor LOGIN' WHERE NOT EXISTS (...) \gexec`; `ALTER ROLE jbh_monitor WITH LOGIN PASSWORD :'pw'`; `GRANT pg_monitor TO jbh_monitor`; `CREATE EXTENSION IF NOT EXISTS pg_stat_statements` (D1).

## 2. Local script

Depends on: 1 (file path and the `pw` variable).

- [x] 2.1 `local-pg-monitor.sh`: `#!/bin/sh`, `set -eu`, header comment, `PG_ADMIN_URL` default, `command -v psql` check, password check, preload `case` (skip / `ALTER SYSTEM` + restart line + exit 0 / other value + exit 1), then `psql -v ON_ERROR_STOP=1 -v pw=... -f initdb/sql/pg-monitor.sql` (D2, D3). Small functions, each under 40 lines.

## 3. First-start script

Depends on: 1.

- [x] 3.1 `initdb/02-create-monitor-role.sh`: replace the inline heredoc with `psql -f /docker-entrypoint-initdb.d/sql/pg-monitor.sql`; keep `set -eu` and the skip guard; update the header (existing volume: `make local-pg-monitor`, see `LOCAL.md`) (D5).

## 4. Make target

Depends on: 2.

- [x] 4.1 `local.mk`: add `local-pg-monitor` to `.PHONY` and the recipe from D4; fix the `local-alloy` comment (Postgres from `make local-up`, or on the Mac after `make local-pg-monitor`).

## 5. Docs

Depends on: 2, 4 (names and behavior).

- [x] 5.1 `LOCAL.md`: rewrite "Existing Postgres volume (a)" and "Postgres installed on the Mac (b)" with `make local-pg-monitor`, the `PG_ADMIN_URL` example, the restart-then-run-again note, the `JBH_PG_MONITOR_DSN` line, and a pointer to `initdb/sql/pg-monitor.sql` (D6).
- [x] 5.2 `CLAUDE.md`: files table rows (D6). `.env.local.example`: one comment line (D6). Disjoint from 5.1; can run in parallel.

Size estimate: 12 files, ~330 changed lines (tests and docs included)
