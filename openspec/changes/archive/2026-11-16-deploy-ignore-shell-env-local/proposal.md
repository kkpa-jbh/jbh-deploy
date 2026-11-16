## Why

The shell profile of a developer can export `POSTGRES_USER`, `POSTGRES_PASSWORD`, `JBH_JWT_SECRET` and `GEMINI_API_KEY` (for example for another project).
Docker Compose prefers shell variables over `--env-file`. So `make local-ide-env` wrote `DATABASE_USERNAME=<other user>` into `jbh.env`,
and `make local-up` gave the containers the same foreign values. The local stack must use `.env.local` as its only source.

## What Changes

- `local.mk`: new variable `LOCAL_CLEAN_ENV` (`env -u <key> ...` for every key name in `.env.local.example`). `LOCAL_COMPOSE` and the two script calls
  (`local-swap`, `local-ide-env`) use it. `local-ide-env` gets `IDE_ENV_FILE ?= jbh.env`, so a check can write to another file.
- `local-swap-env.sh`: header comment only (a run through make ignores the shell exports, a run by hand reads them). No logic change.
- `LOCAL.md`: one short note (shell exports no longer reach `make local-*`) and one warning (a `jbh-local-pgdata` volume keeps the user it was created with).
- No change in `Makefile`, `compose*.yaml`, `.env*` files, `README.md`, `CLAUDE.md`. No database change.

## Capabilities

### New Capabilities
none

### Modified Capabilities
- `local-swap-env`: a run through `make` ignores the shell exports of the keys in `.env.local.example`; `make local-ide-env` takes an output file.
- `deploy-docs`: `LOCAL.md` tells the reader that `.env.local` is the only source and warns about an existing Postgres volume.

## Impact

Local make targets only. A developer who set `POSTGRES_PASSWORD=x make local-up` on purpose must now edit `.env.local`. The VPS targets do not change.
