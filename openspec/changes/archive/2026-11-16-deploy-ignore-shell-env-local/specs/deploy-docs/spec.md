## ADDED Requirements

### Requirement: Docs say that .env.local is the only source
`LOCAL.md` SHALL say that `make local-*` ignores the shell exports of the keys in `.env.local.example` and that the reader changes values in `.env.local`.
It SHALL warn that a `jbh-local-pgdata` volume keeps the Postgres user and password it was created with (Postgres sets them only at the first start),
so `.env.local` must match the volume, or the volume must be recreated. The text SHALL NOT tell the reader to run a command that deletes data without saying so.
`local-swap-env.sh` SHALL say in its header comment that a run through make ignores the shell exports and a run by hand reads them.
`Makefile`, `compose.yaml`, `compose.local.yaml`, `.env.example`, `.env.local.example`, `README.md`, `DEPLOY.md` and `.github/` SHALL NOT change.

#### Scenario: Reader wonders why a shell export has no effect
- **WHEN** a reader looks in `LOCAL.md` for the shell variable `POSTGRES_USER`
- **THEN** the text says the shell value is ignored by `make local-*` and `.env.local` is the source

#### Scenario: Reader changes the Postgres user on an old volume
- **WHEN** a reader looks in `LOCAL.md` for what happens when `POSTGRES_USER` differs from the volume
- **THEN** the text says the volume keeps its first user and names the two fixes (match `.env.local`, or recreate the volume and lose its data)

#### Scenario: Other files are untouched
- **WHEN** `git diff --stat main -- Makefile compose.yaml compose.local.yaml .env.example .env.local.example README.md DEPLOY.md .github` runs after the change
- **THEN** it prints nothing
