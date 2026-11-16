## Context

Compose resolves `${VAR}` from the shell first and from `--env-file` second. A developer whose `~/.zshrc` exports `POSTGRES_USER`, `POSTGRES_PASSWORD`,
`JBH_JWT_SECRET` or `GEMINI_API_KEY` (values of another project) gets those values in `make local-up` and in `jbh.env` (`make local-ide-env`).
The user keeps the exports (the other project needs them) and wants `make local-*` to ignore them.
The archived designs `deploy-derive-ide-env` and `deploy-add-ide-env-file` stay valid, in particular the rule that the raw compose JSON is never printed (their D4).
Scope: make, one comment in the script, and docs. No database change. Unit tests: excluded by the user, so there is no test blueprint.

## Decisions

### D1. One prefix, built from the example file
`local.mk` gets two variables:

```make
LOCAL_ENV_KEYS = $(shell sed -n 's/^[^A-Za-z]*\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env.local.example)
LOCAL_CLEAN_ENV = env $(addprefix -u ,$(LOCAL_ENV_KEYS))
```

The key names come from `.env.local.example`, so there is no second hand-kept list: a key added to the example is unset from then on.
The sed rule takes `KEY=` at the start of a line, with an optional comment prefix (`# `). That is how the commented optional key `JBH_PG_MONITOR_DSN` is also found
(a shell export of it would redirect Alloy to another Postgres). Result today: 19 keys, in file order:
`POSTGRES_USER POSTGRES_PASSWORD JBH_PG_MONITOR_PASSWORD JBH_PG_MONITOR_DSN JBH_JWT_SECRET GOOGLE_CLIENT_IDS GMAIL_HOST GMAIL_PORT GMAIL_USERNAME GMAIL_APP_PASSWORD GMAIL_FROM
STATEMENT_TEXT_SOURCE STATEMENT_LLM AZURE_DI_ENDPOINT AZURE_DI_API_KEY AZURE_DI_PAGES_PER_REQUEST OPENROUTER_API_KEY GEMINI_API_KEY JEV_API_KEY`.
Prose lines of the example have no `KEY=` at the start, so they do not match. `LOCAL_ENV_FILE` is not in the example, so it is not unset: the checks still choose the env file.
No literal `#` in the make text: make reads `#` as a comment start. The rule `[^A-Za-z]*` skips `# ` without it.

Recursive `=` (not `:=`) on purpose: the `$(shell ...)` runs only when a local recipe expands the variable, so the VPS targets never read `.env.local.example`
(it is not needed on the VPS). `Makefile` does not change.
Checked on this machine: GNU make 3.81 (the macOS make) parses the construct (`$(addprefix -u ,...)` keeps the space after `-u`), and BSD `env` accepts many `-u` flags.
A shell value of a listed key is gone in the child (`POSTGRES_USER=canary make ...` gives an empty value), and `LOCAL_ENV_FILE` passes through.
Rejected: `env -i` (it also drops `PATH`, `HOME`, `DOCKER_HOST` and the Docker context); a hand-kept list in `local.mk` (a second copy of the example file);
`unexport` in make (each key needs its own line, so the list is hand-kept again, and make 3.81 `unexport` of a shell-only variable is not reliable).

### D2. Where the prefix goes
- `LOCAL_COMPOSE = $(LOCAL_CLEAN_ENV) docker compose --env-file .env.local -f compose.local.yaml`. Every target that uses it (`up`, `down`, `ps`, `logs`, `stop`, `restore`, `alloy`) is covered, including `stop`, which renders the file again.
- `local-swap`: `vars="$$($(LOCAL_CLEAN_ENV) sh ./local-swap-env.sh $(s))"`. The masked output then holds the `.env.local` values.
- `local-ide-env`: `@$(LOCAL_CLEAN_ENV) sh ./local-swap-env.sh --write-all $(IDE_ENV_FILE)`.
- `local-pg-monitor`: no prefix. It already reads only `JBH_PG_MONITOR_PASSWORD` from `.env.local` with `sed`, and the assignment before `sh` overrides the shell. The script needs `PG_ADMIN_URL` and `PGPASSWORD` from the shell on purpose, and neither is in the example file.
- `local-up`, `local-alloy` keep their `test -f .env.local` line.
- The script itself is not changed (D3), so `sh ./local-swap-env.sh` by hand still reads the shell, as the archived specs say.

### D3. Header comment in the script, no logic change
The header of `local-swap-env.sh` gets two lines: a run through `make local-swap` or `make local-ide-env` removes the shell exports of the keys in `.env.local.example` first; a run by hand reads them.
Rejected: unsetting inside the script (a second list or a second reader of the example file, and the by-hand run is how the canary checks of the archived specs work). Print mode and write mode output stay the same.

### D4. `IDE_ENV_FILE` to test without touching `jbh.env`
`IDE_ENV_FILE ?= jbh.env` in `local.mk` (before the targets), used by `local-ide-env`. `make local-ide-env IDE_ENV_FILE=<scratch>/jbh.env` writes there.
The script already accepts a path (the folder must exist and be writable). `?=` lets the environment or the command line set it. The default keeps the old behavior and `make -n local-ide-env` still ends with `--write-all jbh.env`.
Rejected: a new script option (no logic change wanted); a second target (a copy of the recipe).

### D5. LOCAL.md: one note, one warning
In "One-time setup" or "Daily use" (after the `.env.local` step), one short note: `make local-*` ignores shell exports of the keys in `.env.local.example` (for example `POSTGRES_USER` from `~/.zshrc`); change values in `.env.local`.
One warning (Catches section): Postgres sets its user and password only at the first start of an empty volume. A `jbh-local-pgdata` volume keeps the first user. If `POSTGRES_USER` or `POSTGRES_PASSWORD` in `.env.local` differ from it, IAM and finance cannot log in.
Fix: set `.env.local` to the volume's values, or recreate the volume and lose its data: `make local-down`, then `docker volume rm jbh-local_jbh-local-pgdata`, then `make local-up`.
The volume is named in `compose.local.yaml` as `jbh-local-pgdata`; with the project name `jbh-local` the Docker name is `jbh-local_jbh-local-pgdata` (`jbh-pgdata` is the VPS volume, not this one).
Each is a few lines. `CLAUDE.md` and `README.md` stay as they are.

### D6. Secrets (binding)
Nothing prints a real value. The checks use canary values and look only at counts (`grep -c`) and at the final file. Never run `docker compose ... config` without `-q`.
The prefix removes the shell secrets from the child process, so the only secret source is `.env.local`. The raw JSON rule of the archived D4 holds.

## Responsibilities

- `local.mk`: runs the local commands with `.env.local` as the only source (`LOCAL_ENV_KEYS`, `LOCAL_CLEAN_ENV`, `IDE_ENV_FILE`). Changes when the local make commands change.
- `local-swap-env.sh`: unchanged logic (header comment only). Renders compose env as IDE values.
- `LOCAL.md`: tells the reader that `.env.local` is the only source and warns about an old volume. Changes when the workflow changes.
- `Makefile`, `compose*.yaml`, `.env*`, `README.md`, `CLAUDE.md`: unchanged.

## Concurrency

none. Each make call starts its own short-lived processes. The change only removes variables from a child environment; no shared state, no second writer (the write to `<file>` is atomic as before).

## Database

No change. No table, column, index, migration or volume change. The Design-Gate `database` does not apply. The volume warning is documentation only.

## Test contract (checks, no unit tests)

Unit tests: excluded by the user. The leader runs these checks. None starts or stops a container. Never run `make local-up`, `make local-swap` or any target that starts or stops one (use `make -n`).
`K` = `env -u POSTGRES_USER -u POSTGRES_PASSWORD -u JBH_PG_MONITOR_PASSWORD -u JBH_PG_MONITOR_DSN -u JBH_JWT_SECRET -u GOOGLE_CLIENT_IDS -u GMAIL_HOST -u GMAIL_PORT -u GMAIL_USERNAME -u GMAIL_APP_PASSWORD -u GMAIL_FROM -u STATEMENT_TEXT_SOURCE -u STATEMENT_LLM -u AZURE_DI_ENDPOINT -u AZURE_DI_API_KEY -u AZURE_DI_PAGES_PER_REQUEST -u OPENROUTER_API_KEY -u GEMINI_API_KEY -u JEV_API_KEY` (19 flags).
`S` = a new empty folder in the scratch area.

| ID | Command | Expected |
|----|---------|----------|
| C1 | `make -n local-ide-env` | one line: `K sh ./local-swap-env.sh --write-all jbh.env` |
| C2 | `make -n local-up` | has `K docker compose --env-file .env.local -f compose.local.yaml up -d` (the `test -f` line comes first) |
| C3 | `make -n local-swap s=jbh-iam` | has `K sh ./local-swap-env.sh jbh-iam` inside `vars="$(...)"` and `K docker compose --env-file .env.local -f compose.local.yaml stop jbh-iam` |
| C4 | `make -n local-restore s=jbh-iam`, `make -n local-down`, `make -n local-alloy` | each docker line starts with `K docker compose` |
| C5 | `make -n local-ide-env \| grep -o -- ' -u ' \| wc -l`; `make -n local-ide-env \| grep -c -- '-u LOCAL_ENV_FILE'`; same for `-u IDE_ENV_FILE` | `19`; `0`; `0`. The 19 names equal the output of `sed -n 's/^[^A-Za-z]*\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env.local.example` |
| C6 | `make -n local-pg-monitor` | no `env -u`: the line stays as it is today |
| C7 | `sh -n local-swap-env.sh` | exit 0, no output |
| C8 | `docker compose --env-file .env.example -f compose.yaml config -q && docker compose --env-file .env.local.example -f compose.local.yaml config -q` | exit 0 |
| C9 | canary: `POSTGRES_USER=canary-user POSTGRES_PASSWORD=canary-pg JBH_JWT_SECRET=canary-jwt GEMINI_API_KEY=canary-gem LOCAL_ENV_FILE=.env.local.example make local-ide-env IDE_ENV_FILE=S/jbh.env >S/out 2>S/err` | exit 0. `S/out` is one line: `S/jbh.env: 33 keys`. `S/err` is empty. `grep -c canary S/jbh.env` prints `0`, and `grep -c canary S/out S/err` prints `0` for both. `S/jbh.env` equals the 33 lines of E4 in the archived `deploy-add-ide-env-file` design (`DATABASE_USERNAME=jbh_admin`, `DB_USERNAME=jbh_admin`, `JBH_ADMIN_PASS=change-me`, `JBH_JWT_SECRET=change-me`, `GEMINI_API_KEY=`). Mode `600` (`stat -f %Lp`). `ls -A S` shows no `.jbh-env.*` |
| C10 | control: same canary without the prefix, by hand: `POSTGRES_USER=canary-user ... LOCAL_ENV_FILE=.env.local.example sh ./local-swap-env.sh --write-all S/c.env` | `grep -c canary S/c.env` prints `4` (proves the canary can reach the file, so C9's `0` means something). Never print `S/c.env` |
| C11 | default file: `git status --short jbh.env` before and after the checks | unchanged. No check writes the real `jbh.env` (C9 uses `IDE_ENV_FILE`) |
| C12 | `git diff --stat main -- Makefile compose.yaml compose.local.yaml .env.example .env.local.example README.md DEPLOY.md .github CLAUDE.md` | no output |
| C13 | `git diff main -- local-swap-env.sh` | only `#` comment lines changed (`git diff main -- local-swap-env.sh \| grep -E '^[+-][^+-]' \| grep -vE '^[+-]#'` prints nothing) |
| C14 | `grep -nE 'DB_PORT\|OTEL_\|<POSTGRES' local.mk` | no match (no env value in `local.mk`) |
| C15 | `grep -n 'ignores\|jbh-local-pgdata' LOCAL.md` | the note (D5) and the warning with both fixes are there |

If `jq` or `docker` is missing, C9 fails with the script's short message; that is not a defect of this change.

## Risks / Trade-offs

- A developer who used `POSTGRES_PASSWORD=x make local-up` on purpose must now edit `.env.local`. This is the wanted behavior (one source) and the LOCAL.md note says so.
- A key that a service reads but that is not in `.env.local.example` still comes from the shell. The compose file uses only keys that the example lists; a new key has to be added to the example, which the project rule already asks for.
- If `.env.local.example` is missing, `LOCAL_ENV_KEYS` is empty and nothing is unset (sed prints an error to stderr, make goes on). The file is in git, so this is a broken checkout; accepted, no `$(error)` because a parse error would also stop the VPS targets.
- `$(shell sed ...)` runs once for each expansion of `LOCAL_CLEAN_ENV` (a few per recipe). It is one `sed` on a 42 line file; the cost is not measurable.
- The volume warning only informs. The two fixes are in the docs; the one that deletes data says so.
