## ADDED Requirements

### Requirement: Local make targets ignore the shell exports
`local.mk` SHALL define `LOCAL_CLEAN_ENV` as `env` followed by `-u <KEY>` for every key name in `.env.local.example`, read from that file at make time (no second list in `local.mk`).
`LOCAL_COMPOSE`, the `local-swap` call of `local-swap-env.sh` and the `local-ide-env` call SHALL start with `$(LOCAL_CLEAN_ENV)`,
so `.env.local` is the only source of those keys. `LOCAL_ENV_FILE` SHALL NOT be unset. `Makefile` SHALL NOT change, and the VPS targets SHALL NOT read `.env.local.example`.
A run of `local-swap-env.sh` by hand SHALL still read the shell.

#### Scenario: The prefix holds every key of the example file
- **WHEN** `make -n local-ide-env` runs
- **THEN** it prints one line that starts with `env -u POSTGRES_USER -u POSTGRES_PASSWORD -u JBH_PG_MONITOR_PASSWORD -u JBH_PG_MONITOR_DSN -u JBH_JWT_SECRET`, holds 19 `-u` flags,
  has no `-u LOCAL_ENV_FILE`, and ends with `sh ./local-swap-env.sh --write-all jbh.env`

#### Scenario: Shell secrets do not reach the IDE file
- **WHEN** `POSTGRES_USER=canary-user POSTGRES_PASSWORD=canary-pg JBH_JWT_SECRET=canary-jwt GEMINI_API_KEY=canary-gem LOCAL_ENV_FILE=.env.local.example make local-ide-env IDE_ENV_FILE=<scratch>/jbh.env` runs
- **THEN** `<scratch>/jbh.env` has 33 lines, has no `canary` text, and holds `DATABASE_USERNAME=jbh_admin`, `JBH_JWT_SECRET=change-me` and `GEMINI_API_KEY=`

### Requirement: The IDE env file name can be set
`make local-ide-env` SHALL write to `$(IDE_ENV_FILE)`, which defaults to `jbh.env`.

#### Scenario: Default file
- **WHEN** `make -n local-ide-env` runs
- **THEN** the command ends with `--write-all jbh.env`
