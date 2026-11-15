## ADDED Requirements

### Requirement: Docs describe make local-pg-monitor
`LOCAL.md` SHALL tell the user to run `make local-pg-monitor` for an existing local Postgres volume (with `PG_ADMIN_URL=postgresql://jbh_admin@localhost:5433/postgres`) and for the Postgres installed on the Mac (default URL),
SHALL say that a restart may be needed and that the target must then run again, and SHALL point to `initdb/sql/pg-monitor.sql` for what it runs. It SHALL NOT keep the hand-written monitor SQL or the `postgresql.conf` lines.
`CLAUDE.md` SHALL list `initdb/sql/pg-monitor.sql`, `local-pg-monitor.sh` and the `local-pg-monitor` target in its files table.
`compose.yaml`, `compose.local.yaml`, `.env.example`, `Makefile`, `DEPLOY.md`, `ci-deploy.sh`, `README.md` and `.github/` SHALL NOT change.

#### Scenario: Reader finds the one command
- **WHEN** a reader looks in `LOCAL.md` for how to prepare the Mac Postgres for Alloy
- **THEN** the text says `make local-pg-monitor`, the restart note and the second run, and no `CREATE ROLE` SQL block

#### Scenario: Production files are untouched
- **WHEN** `git diff --stat main -- compose.yaml compose.local.yaml .env.example DEPLOY.md Makefile ci-deploy.sh README.md .github` runs after the change
- **THEN** it prints nothing
