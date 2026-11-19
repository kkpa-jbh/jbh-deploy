## Why

`make local-swap` prints the env vars for an IDE run from echo lines in `local.mk`. `LOCAL.md` holds the same list in two more places
(a table and an OTLP block). The values come from `compose.local.yaml`, so the four copies drift apart. JBH-56 already needed one
extra echo line (archived `deploy-add-local-pg-monitor`, D10) to keep make and `LOCAL.md` equal. This change removes the copies.

## What Changes

- New `local-swap-env.sh <service>` (repo root, POSIX sh). It renders `compose.local.yaml` with `docker compose config --format json`,
  and prints that service's `environment` as IDE values, one `KEY=value` per line, sorted by key.
- The script translates Docker hostnames to Mac addresses, and hides secrets (`<from .env.local>`) inside the jq filter. Raw compose JSON never reaches the terminal.
- `make local-swap s=<service>` calls the script. The echo lines and the `case` block in `local.mk` are removed.
- `LOCAL.md` drops the env var table and the IDE var block. It says "run `make local-swap s=<service>`" and keeps why the ports differ.
- `CLAUDE.md` lists the new script in its files table.
- No change to `compose.local.yaml`, `compose.yaml`, `.env.local.example`, `README.md`, `Makefile`, `.github/`. No database change.

## Capabilities

### New Capabilities
- `local-swap-env`: how `make local-swap` produces the IDE env vars (one source, translation, secret masking, checks).

### Modified Capabilities
- `deploy-docs`: `LOCAL.md` no longer lists the IDE env vars; it points to `make local-swap`.
- `notification-service-deploy`: the "Swap for the IDE" scenario states the printed lines.

## Impact

Files: `local-swap-env.sh` (new), `local.mk`, `LOCAL.md`, `CLAUDE.md`. Local dev only. Needs `jq` and `docker` on the developer machine.
Replaces D10 of the archived `deploy-add-local-pg-monitor`. Ticket JBH-56, same branch and draft PR.
