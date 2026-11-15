## Context

JBH-56, follow-up of the archived change `deploy-add-grafana-alloy` (read its "Database" section and D7). Alloy needs role `jbh_monitor`, `GRANT pg_monitor` and
`pg_stat_statements`. A new Docker volume gets them from `initdb/02-create-monitor-role.sh`. An existing volume, or the Homebrew Postgres on the Mac, gets nothing: `LOCAL.md` asks the user to run SQL by hand.

Facts (checked by the leader):

- The Mac runs Homebrew `postgresql@16` on port 5432, the user is a superuser. `shared_preload_libraries` is empty, role `jbh_monitor` does not exist. No local Docker volume exists today.
- Docker `jbh-postgres` (`compose.local.yaml`) publishes Mac port 5433, admin user `POSTGRES_USER` (default `jbh_admin`), and already sets `shared_preload_libraries=pg_stat_statements` and `pg_stat_statements.track=top` in its command.
- `./initdb` is mounted at `/docker-entrypoint-initdb.d` in both compose files. The image runs top-level `*.sh`, `*.sql`, `*.sql.gz` files only, not files in subfolders.
- `local.mk` is included by `Makefile` with `-include local.mk` and does not load `.env.local`.

User decisions (binding): not Liquibase; keep initdb for new Docker volumes; one shared SQL file in a subfolder; preload by a safe check in the script only (never in the shared SQL); SRP only, no OCP/DIP abstraction; the leader never restarts Postgres, the script prints the command.

Docs checked with Context7 (`/websites/postgresql`, 2026-11-15): `\gexec` runs each value of the query result as SQL; `:'var'` quotes a psql variable as a SQL literal (safe for the password);
`ALTER SYSTEM` cannot run inside a transaction block or function. psql variables are not replaced inside a `DO $$ ... $$` body (it is one string literal), so the role is created with `SELECT ... \gexec`, not with `DO`.

## Responsibilities

| File | One responsibility |
|------|--------------------|
| `initdb/sql/pg-monitor.sql` | Create (or update) the monitor role, its grant and the extension. Nothing else. |
| `local-pg-monitor.sh` | Check the preload setting of one Postgres, then run the shared SQL against it. |
| `initdb/02-create-monitor-role.sh` | Run the shared SQL on the first start of a new Docker volume (and keep the skip guard). |
| `local.mk` (`local-pg-monitor`) | Read the password from `.env.local` and call the script. |
| `LOCAL.md`, `CLAUDE.md`, `.env.local.example` | Docs and one comment. |

No new class or abstraction. No second implementation exists, so no seam is added.

## Decisions

### D1. Shared SQL file `initdb/sql/pg-monitor.sql`

Path is `initdb/sql/pg-monitor.sql`. It is in a subfolder, so the image entrypoint never runs it alone (it has no `pw` value then). It is used by `02-create-monitor-role.sh`, by `local-pg-monitor.sh` and, later, by JBH-84.
Content (the password only through the psql variable `pw`):

```sql
-- header comment: what it does, who calls it, needs -v pw=<password>, safe to run many times
SELECT 'CREATE ROLE jbh_monitor LOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'jbh_monitor')
\gexec
ALTER ROLE jbh_monitor WITH LOGIN PASSWORD :'pw';
GRANT pg_monitor TO jbh_monitor;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

Re-run: the role is created only when missing; the other three statements do nothing new the second time, except that the password is set again. The file has no `ALTER SYSTEM` and no preload logic (the VPS sets preload in the compose command).
It must run in database `postgres` (the callers pass `--dbname postgres` or the URL). No `BEGIN`/`COMMIT`: each statement runs alone.

### D2. Script `local-pg-monitor.sh` (repo root, next to `backup-db.sh`)

`#!/bin/sh`, `set -eu`, `cd "$(dirname "$0")"`. Header comment: what it does, who calls it (`make local-pg-monitor`, or by hand), env vars it reads (`PG_ADMIN_URL`, `JBH_PG_MONITOR_PASSWORD`, and `PGPASSWORD` read by psql).
Steps, each a small shell function (`check_psql`, `check_password`, `preload_state`, `run_sql`), in this order:

1. `command -v psql` or stop: `psql not found. Install the PostgreSQL client (macOS: brew install libpq, then add it to PATH).` Exit 1.
2. `JBH_PG_MONITOR_PASSWORD` empty or unset: `JBH_PG_MONITOR_PASSWORD is not set` and exit 1. (Different from initdb, which skips: here the user asked for the role.)
3. Read the preload value: `psql "$PG_ADMIN_URL" -v ON_ERROR_STOP=1 -Atqc 'SHOW shared_preload_libraries'`. Remove spaces. Then:
   - the list holds `pg_stat_statements` (test `case ",$value," in *,pg_stat_statements,*`) -> go on to step 4;
   - empty -> `ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements'` (one `psql -c` call, not in a transaction block; `pg_stat_statements.track` stays at its default `top`, user decision at the design gate), print the restart line, print `Then run: make local-pg-monitor again`, and **exit 0 without running the SQL file**;
   - other libraries -> print the value and `not changing it: add pg_stat_statements by hand`, exit 1, change nothing.
4. Run `psql "$PG_ADMIN_URL" -v ON_ERROR_STOP=1 -v pw="$JBH_PG_MONITOR_PASSWORD" -f initdb/sql/pg-monitor.sql`, then print one line `jbh_monitor is ready`.

The restart line: `Restart Postgres to load the library. Homebrew: brew services restart postgresql@16 (the command depends on how Postgres is installed).` The script never restarts Postgres.
`ALTER SYSTEM` writes `postgresql.auto.conf` in the data directory of the Postgres it connects to. It needs a superuser, which is the admin the user passes.
`pg_stat_statements.track` is not set: `top` is its default. The user dropped that `ALTER SYSTEM` line at the design gate, because nobody had tested it before the library loads.

### D3. Admin connection: `PG_ADMIN_URL`

The script reads `PG_ADMIN_URL`, default `postgresql://localhost:5432/postgres` (the Mac Postgres, current OS user). For the Docker volume: `PG_ADMIN_URL=postgresql://jbh_admin@localhost:5433/postgres make local-pg-monitor`.
The default lives in the script only (`PG_ADMIN_URL=${PG_ADMIN_URL:-postgresql://localhost:5432/postgres}`); the make target passes the environment through. No admin password is read from or written to any file: psql reads `PGPASSWORD` or `~/.pgpass`.
The URL must not hold a password (the docs say so). The script never prints the URL with credentials: it prints only the host and port part it was given in a plain message, or nothing.

### D4. Make target and the password

`local.mk` gets `local-pg-monitor` (in `.PHONY`). The recipe starts with `@`, so make does not echo the command:

```make
local-pg-monitor:
	@test -f .env.local || (echo "Missing .env.local. Run: cp .env.local.example .env.local" && exit 1)
	@JBH_PG_MONITOR_PASSWORD="$$(sed -n 's/^JBH_PG_MONITOR_PASSWORD=//p' .env.local | tail -n 1)" sh ./local-pg-monitor.sh
```

Only this one key is read with `sed`. `.env.local` is not sourced, because other lines (mail values with spaces) could break a shell. The value is never printed with `echo`. It is in the environment of the script only.
The script passes it to psql as `-v pw=...`, so it is visible in the process list of the user's own machine while psql runs: accepted for a local dev password (same as the old inline script). `sh ./local-pg-monitor.sh` avoids a dependence on the file mode.
The `local-alloy` comment changes to `Postgres must run (make local-up, or Postgres on your Mac: make local-pg-monitor first)`.

### D5. `initdb/02-create-monitor-role.sh`

Keep the header, `set -eu` and the skip guard (the prod compose mounts the same folder and does not pass the password). Replace the inline heredoc with:
`psql -v ON_ERROR_STOP=1 -v pw="$JBH_PG_MONITOR_PASSWORD" --username "$POSTGRES_USER" --dbname postgres -f /docker-entrypoint-initdb.d/sql/pg-monitor.sql`.
The header comment points to `LOCAL.md` and `make local-pg-monitor` for an existing volume. On a new volume the role does not exist, so D1 creates it as before: same result as the old script.

### D6. Docs

- `LOCAL.md`: "Existing Postgres volume (a)" and "Postgres installed on the Mac (b)" become short sections that use `make local-pg-monitor` (Docker volume: with `PG_ADMIN_URL=postgresql://jbh_admin@localhost:5433/postgres`; Mac: default). The Mac section keeps the `JBH_PG_MONITOR_DSN` override line and the "run it again after the restart" step. One pointer: "what it runs: `initdb/sql/pg-monitor.sql`". The `postgresql.conf` lines and the hand-written SQL are removed.
- `CLAUDE.md`: files table gets `initdb/sql/pg-monitor.sql`, `local-pg-monitor.sh`, and `local-pg-monitor` in the `local.mk` row; the `initdb/` row says `02-create-monitor-role.sh` runs the shared SQL.
- `.env.local.example`: one comment line: `initdb/` reads the password on a new volume; `make local-pg-monitor` reads it for an existing Postgres. No variable changes.
- `README.md` is not touched: no route, port, Consul name, compose or env var changes (CLAUDE.md "System map sync").

## Database

The database gate applies. No table, column, index, constraint, view or Liquibase migration. The objects are the ones already confirmed in `deploy-add-grafana-alloy`, plus a local server setting.

| Object | Value | Where it is created |
|--------|-------|---------------------|
| Role | `jbh_monitor`, `LOGIN`, password from `JBH_PG_MONITOR_PASSWORD`; not superuser, no `CREATEDB` (role defaults) | `initdb/sql/pg-monitor.sql` |
| Grant | `GRANT pg_monitor TO jbh_monitor` (statistics only, no table data) | same file |
| Extension | `pg_stat_statements` in database `postgres` | same file |
| Server setting | `shared_preload_libraries = 'pg_stat_statements'` via `ALTER SYSTEM` (`track` stays at its default `top`), only when the value is empty, on a local Postgres | `local-pg-monitor.sh` |

**Why this design.**

- One SQL file means one definition for the new volume, the existing volume, the Mac Postgres and (JBH-84) the VPS. A second copy of the SQL would drift.
- `SELECT ... \gexec` makes "create when missing" work without `DO`, so `:'pw'` stays valid (psql does not replace variables inside `$$` bodies). `ALTER ROLE ... PASSWORD :'pw'` always runs, so a changed password in `.env.local` reaches the role on the next run.
- Preload stays out of the shared file: on the VPS and in the Docker command it is set by the compose command line, and `ALTER SYSTEM` there would create a second source of truth. The script decides only for a local Postgres.
- `ALTER SYSTEM` instead of editing `postgresql.conf`: no file path to find (Homebrew paths differ by version/CPU), no text edit, and it is reversible with `ALTER SYSTEM RESET`. It needs a restart to take effect: the script prints it.
- Safe check: only an empty value is changed. A non-empty value without the library is the user's own setup; the script stops and prints it.

**Rejected.** Liquibase (user decision: this is a server/role setup, not a service schema, and no service owns it). Editing `postgresql.conf` with `sed` (fragile). Putting the preload in the SQL file (breaks the VPS rule). One SQL per use (drift). Appending to a non-empty preload list automatically (could break the user's other extensions; stops with the value instead).

**Index plan.** No index. The change creates no table and adds no query path. Read patterns: Alloy's exporter reads `pg_stat_database`, `pg_stat_statements` and other system views every 30 s; these are system objects with their own access paths.
`pg_stat_statements` is a view over shared memory, not a table.

**Existing data.** Nothing is migrated or deleted. Running on a Postgres that already has the role changes its password and keeps the grant. Local dev data only.

## Concurrency

| Task | Risk | Proposed guard |
|------|------|----------------|
| 1 (shared SQL), 2 (script) | Two runs at the same time: both see no role, both run `CREATE ROLE`, one fails with "role already exists" (check-then-act). With `ON_ERROR_STOP=1` that run exits non-zero. | none needed. This is a manual local command; the failed run leaves the same end state. Run it again. (If JBH-84 runs it from CI, it can wrap the file in `pg_advisory_lock`; not now.) |
| 3 (initdb script) | Runs once, inside the image entrypoint, before the server accepts outside connections. | none |
| 4 (make target) | none | none |

The risk is low and local, so there is no user question. Everything else (`ALTER ROLE`, `GRANT`, `CREATE EXTENSION IF NOT EXISTS`) is safe to repeat.

## Test contract (expected values)

No unit tests (user decision: shell, SQL and docs only). **No test blueprint group.** Verification is static; the leader runs V1-V8 with the build step. V9 is optional, run by the user.

| # | Check | Expected |
|---|-------|----------|
| V1 | `sh -n local-pg-monitor.sh` and `sh -n initdb/02-create-monitor-role.sh` | both exit 0, no output |
| V2 | `make -n local-pg-monitor` | exit 0; prints the `test -f .env.local` and the `sh ./local-pg-monitor.sh` lines; does not print a password value (`.env.local` may not exist: then the first line is the "Missing .env.local" check only) |
| V3 | `ls initdb/*.sql` | no match: the SQL file is not top-level. `ls initdb/sql/pg-monitor.sql` exists |
| V4 | `grep -c 'pw' initdb/sql/pg-monitor.sql`; `grep -n "CREATE ROLE jbh_monitor\|\\\\gexec\|ALTER ROLE jbh_monitor\|GRANT pg_monitor\|CREATE EXTENSION IF NOT EXISTS pg_stat_statements" initdb/sql/pg-monitor.sql` | `:'pw'` appears in `ALTER ROLE` only; all five patterns match; `ALTER SYSTEM` and `DO $$` do not appear (`grep -c` gives 0) |
| V5 | `grep -n 'ALTER SYSTEM SET shared_preload_libraries' local-pg-monitor.sh`; `grep -n 'ALTER SYSTEM' initdb/02-create-monitor-role.sh` | first: one match; second: none |
| V6 | `grep -n 'pg-monitor.sql' initdb/02-create-monitor-role.sh local-pg-monitor.sh`; read `02-create-monitor-role.sh` | each file names the SQL file; in the initdb script the `JBH_PG_MONITOR_PASSWORD:-` guard and `exit 0` come before the `psql` line; no inline `CREATE ROLE` remains |
| V7 | `docker compose --env-file .env.example -f compose.yaml config -q && docker compose --env-file .env.local.example -f compose.local.yaml config -q` | both exit 0, no output |
| V8 | `git diff --stat main -- compose.yaml compose.local.yaml .env.example DEPLOY.md Makefile ci-deploy.sh README.md .github` | empty |
| V9 (optional, user) | On the Mac: `make local-pg-monitor` (first run); `brew services restart postgresql@16`; `make local-pg-monitor`; then `make local-pg-monitor` again; then `psql -d postgres -Atc "SELECT rolname FROM pg_roles WHERE rolname='jbh_monitor'"` | run 1: prints the restart line, exit 0, no role yet. After restart, run 2: `jbh_monitor is ready`, exit 0. Run 3: same output, exit 0. The query prints `jbh_monitor`. `SHOW shared_preload_libraries` prints `pg_stat_statements`. With another library in the setting: exit 1 and the value is printed |

## Risks

- `.env.local` with the password line missing or empty: the script stops with a clear message (D2, step 2).
