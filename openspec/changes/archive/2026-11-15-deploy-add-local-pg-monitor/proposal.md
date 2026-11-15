## Why

Alloy reads Postgres with the role `jbh_monitor`. On a Postgres that already has data, `initdb/` does not run, so the user must create the role,
the extension and the preload setting by hand. `LOCAL.md` lists those steps ("Existing Postgres volume", "Postgres installed on the Mac").
They are easy to get wrong and hard to repeat. This change (JBH-56, follow-up of `deploy-add-grafana-alloy`) turns them into one command: `make local-pg-monitor`.

## What Changes

- New `initdb/sql/pg-monitor.sql`: the one SQL file for the monitor role, the grant and the extension. It can run many times. It sits in a subfolder, so the Postgres image does not run it by itself.
- New `local-pg-monitor.sh` (repo root): checks `shared_preload_libraries` on one Postgres, then runs the shared SQL file. It never restarts Postgres.
- `initdb/02-create-monitor-role.sh`: runs the shared SQL file instead of its own inline SQL. The skip guard stays.
- `local.mk`: new target `local-pg-monitor`. The `local-alloy` comment is fixed (a Postgres on the Mac also works).
- Docs: `LOCAL.md` replaces the two manual SQL steps with `make local-pg-monitor`; `CLAUDE.md` files table; one comment in `.env.local.example`.
- **No change:** `compose.yaml`, `compose.local.yaml`, `.env.example`, `Makefile`, `DEPLOY.md`, `ci-deploy.sh`, `.github/`, `README.md`.

## Capabilities

### New Capabilities

none

### Modified Capabilities

- `postgres-monitoring`: the monitor objects now come from one shared SQL file that can run again; new requirements for the make target and the preload check.
- `deploy-docs`: `LOCAL.md` and `CLAUDE.md` describe the new target.

## Impact

- Files: `initdb/sql/pg-monitor.sql` (new), `local-pg-monitor.sh` (new), `initdb/02-create-monitor-role.sh`, `local.mk`, `LOCAL.md`, `CLAUDE.md`, `.env.local.example`.
- Not included: running the same SQL on the VPS (JBH-84). The shared file is made so JBH-84 can reuse it; it does not change `compose.yaml` here.
- No Liquibase, no new volume, no change to the data of the services.
