## Context

`make local-swap` prints masked env vars for one service. To run a service in IntelliJ, the developer wants the real values in one file,
and every run configuration points to it (EnvFile plugin). `compose.local.yaml` stays the one source: the file is generated, never edited by hand.
The archived design `deploy-derive-ide-env` (D1 to D9, checks V1 to V15) stays valid unless this document says otherwise.
Scope: shell, make and docs only. No database change. Unit tests: excluded by the user, so there is no test blueprint.

## Decisions

### D1. A second mode in the same script, one set of rules
`local-swap-env.sh --write-all <file>` is a new mode of the existing script. The jq rules (`secret`, `host`, `add_db_port`, `translate`) move into one shell variable `JQ_RULES`,
plus one new def `entries($svc)` (the translated, not masked, environment of a service). Both modes build their filter as `JQ_RULES` plus a short tail:
- print mode tail: `entries($svc) | map(mask) | sort_by(.key) | .[] | "KEY=value"` (same output as before: V4 to V7 hold);
- write mode tail: the union of D2.
Masking (`mask`) is used only by the print mode. Rejected: a second script (the rules would be copied and drift); a `--no-mask` flag on the print mode (one more way to print a secret).

### D2. Union rules
For each of the four swappable services (shell variable `SWAPPABLE`, in the order `jbh-iam jbh-personal-finance jbh-notification jbh-gateway`), take `entries($svc)`, tag each entry with its service,
drop the excluded keys, group by key, then:
- one distinct value in the group: output `KEY=value` once;
- more than one distinct value: output `!KEY in svc1,svc2` (services in `SWAPPABLE` order). A `!` line is never a valid key, so the shell can tell the two kinds apart.
The groups come out sorted by key (jq `group_by`, code point order, upper case ASCII).
An empty value and a non-empty value of the same key are different values (a conflict).
Excluded keys: shell variable `EXCLUDED_KEYS="SPRING_PROFILES_ACTIVE"`, space separated, passed with `--arg`. Comment: the key would start the `local` profile in `jbh-gateway` too; each run configuration sets its own profile.
Today no key conflicts. Translation runs before the comparison, so two Docker names that map to the same Mac address are equal.

### D3. Conflicts: fail, write nothing, never print a value
The shell reads the jq output into a variable. Before any file work it runs `sed -n 's/^!\(.*\)/local-swap-env.sh: conflicting values for \1/p'` on it.
If that prints anything, it goes to stderr and the script exits 1. The sed prints only the `!` lines, which hold a key and service names. jq stderr stays on `/dev/null` (jq errors can quote values).
The target file is not touched (the temporary file is not created yet), so an older `jbh.env` stays.

### D4. Secrets and the file (binding)
`jbh.env` holds real values: compose renders them from the shell and `.env.local`. So:
- `umask 077` is set inside `write_env_file`; the temporary file comes from `mktemp "<dir of file>/.jbh-env.XXXXXX"` (same folder, so `mv` is atomic and keeps mode 600).
- `trap 'rm -f "$tmp"' EXIT` is set right after `mktemp`. After a good `mv` the path no longer exists, so the trap does nothing. Any failure or signal removes the temporary file.
- The content is written with the shell builtin `printf '%s\n' "$lines" > "$tmp"`: no process argument holds a value.
- stdout gets one line on success: `<file>: <N> keys`. stderr gets short messages only. No `set -x`, no `echo "$json"`, no debug output.
- The folder of `<file>` must exist and be writable; if not, one line names the folder and nothing is created.
- The raw compose JSON rule of the archived D4 holds: JSON only in a shell variable, piped to jq with `printf '%s'`, compose and jq stderr to `/dev/null`.
Residual risk (accepted by the user): the file is a plain-text secret on disk (mode 600, git-ignored). The Quarkus `.env` symlinks (D7) make the same file visible in two more repos; the docs warn about their `.gitignore`.

### D5. CLI and function split (SRP)
`main` looks at `$1`: `--write-all` goes to `write_all "${2:-}"`; anything else goes to `print_one "$@"` (the old flow, unchanged).
Functions, each well under 40 lines and cyclomatic 10:

| Function | One job |
|----------|---------|
| `fail`, `check_args`, `check_tools_and_file`, `render_json` | unchanged |
| `to_ide_lines` | print mode: runs `JQ_RULES` + print tail for one service |
| `union_lines` | write mode: runs `JQ_RULES` + union tail for all services |
| `report_conflicts` | prints the `!` lines as messages and exits 1, if there are any |
| `write_env_file` | umask, `mktemp`, trap, `printf`, `mv`; prints the one result line |
| `write_all` | write mode flow: check the file argument and its folder, check tools, render, union, report conflicts, write |
| `print_one` | print mode flow (the old `main` body) |
| `main` | choose the mode |

Rejected: a class-like split into several scripts (no second reason to change).

### D6. Checks that change from the archived design
V13 (raw JSON guard) said `mktemp` must not appear. It now appears once, in `write_env_file`, for the final file only. The raw JSON is still never written to a file.
New V13: `grep -nE 'set -x|/tmp/|echo .*json' local-swap-env.sh` has no match, and `grep -n mktemp local-swap-env.sh` has exactly one match, inside `write_env_file`.
V1 to V12, V14 and V15 keep their meaning; V15 also covers `LOCAL.md`-free files only as before (`compose*`, `.env*`, `Makefile`, `README.md`, `.github`).
V14 still holds: `local.mk` has no env var value (`grep -nE 'DB_PORT|OTEL_|<POSTGRES' local.mk` no match).

### D7. Make, git-ignore, docs
- `local.mk`: `.PHONY` gets `local-ide-env`. Target: a comment (writes `jbh.env`, real secrets, re-run after `compose.local.yaml` changes) and `@sh ./local-swap-env.sh --write-all jbh.env`. It holds no value. The script prints its own error when `.env.local` is missing.
- `.gitignore`: one line `jbh.env`.
- `LOCAL.md`: new section "Env file for the IDE (jbh.env)" after "Swap one service": what the file is; real secrets, mode 600, never commit; IntelliJ steps (plugin, Run > Edit Configurations > EnvFile tab > Enable > `+` > `.env file` > `<path>/jbh-deploy/jbh.env`); the profile is set in the run configuration (IAM: `local`; `SPRING_PROFILES_ACTIVE` is not in the file); after `compose.local.yaml` changes, run `make local-ide-env` and restart; a line that newer IntelliJ versions may load an env file without the plugin; `make local-swap` still prints the masked values of one service.
  Quarkus (docs only): from `jbh-deploy`, `ln -s "$PWD/jbh.env" ../jbh-personal-finance/.env` and the same for `../jbh-notification/.env`; warning: run `git check-ignore .env` in that repo first, it must print `.env`. If the run configuration has another working directory, link the `.env` there. No make target.
  The existing Swap section stays; step 1 gets one pointer to the new section.
- `CLAUDE.md`: the local-stack row of the files table adds `jbh.env` (generated, git-ignored) and `make local-ide-env`.
- `compose.local.yaml`, `compose.yaml`, `.env.local.example`, `.env.example`, `Makefile`, `README.md`, `.github/`: unchanged.
Rejected: a make target for the symlinks (it would change two repos from here, and the `.gitignore` of each is not ours to check); `export` lines or quotes in the file (the EnvFile plugin and Quarkus both read plain `KEY=value`).

## Responsibilities

- `local-swap-env.sh` (existing, gets a new job): turns the compose env into IDE values, for one service (masked, printed) or for all four (merged, real, written to one file). Changes when hostnames, ports, the secret rule, or the excluded keys change.
- `local.mk` `local-ide-env` (new target): calls the script with the file name. Changes when the make commands change.
- `.gitignore`: keeps `jbh.env` out of git.
- `LOCAL.md`: explains the IntelliJ and Quarkus setup. Changes when the workflow changes.
- `CLAUDE.md`: file table entry.
- `compose.local.yaml`: unchanged. Stays the one place for env var values.

## Concurrency

none. One short-lived process per call. Two runs at once each write their own temporary file (`mktemp` gives a unique name) and `mv` is atomic, so the last one wins and the file is never half written. A reader (the IDE) sees the old or the new complete file. Nothing else is shared.

## Database

No change. No table, column, index, migration or volume change. The Design-Gate `database` does not apply.

## Test contract (checks, no unit tests)

Unit tests: excluded by the user. The leader runs these static checks. None starts a container.
`U` = `env -u JBH_JWT_SECRET -u GEMINI_API_KEY -u POSTGRES_USER -u POSTGRES_PASSWORD LOCAL_ENV_FILE=.env.local.example`.
`S` = a new empty folder in the scratch area, for example `<scratch>/ide-env` (the file is `S/jbh.env`).

| ID | Command | Expected |
|----|---------|----------|
| E1 | `sh -n local-swap-env.sh` | exit 0, no output |
| E2 | `make -n local-ide-env` | exit 0. Output is `sh ./local-swap-env.sh --write-all jbh.env` |
| E3 | `docker compose --env-file .env.example -f compose.yaml config -q && docker compose --env-file .env.local.example -f compose.local.yaml config -q` | exit 0 |
| E4 | `U sh ./local-swap-env.sh --write-all S/jbh.env >S/out 2>S/err` | exit 0. `S/out` is exactly one line: `S/jbh.env: 33 keys`. `S/err` is empty. `stat -f %Lp S/jbh.env` prints `600`. `ls -A S` shows `err jbh.env out` (no temporary file). `S/jbh.env` equals the 33 lines below |
| E5 | canary: `LOCAL_ENV_FILE=.env.local.example JBH_JWT_SECRET=canary-jwt POSTGRES_PASSWORD=canary-pg GEMINI_API_KEY=canary-gem sh ./local-swap-env.sh --write-all S/c.env >S/cout 2>S/cerr` | exit 0. `grep -c canary S/c.env` prints `4` (the lines `DATABASE_PASSWORD=canary-pg`, `GEMINI_API_KEY=canary-gem`, `JBH_ADMIN_PASS=canary-pg`, `JBH_JWT_SECRET=canary-jwt`). `grep -c canary S/cout S/cerr` prints `0` for both. `S/cout` is one line with `33 keys` |
| E6 | conflict: copy `local-swap-env.sh`, `compose.local.yaml` and `.env.local.example` to a scratch folder `T`; there, in `compose.local.yaml`, change the first `DATABASE_USERNAME` default only: `awk '/DATABASE_USERNAME:/ && !d {sub(/jbh_admin/,"other"); d=1} {print}'`. In `T` run `U sh ./local-swap-env.sh --write-all out.env`, once with no `out.env`, once after `echo old > out.env` | exit 1 both times. stdout empty. stderr is exactly `local-swap-env.sh: conflicting values for DATABASE_USERNAME in jbh-personal-finance,jbh-notification`. First run: `out.env` does not exist. Second run: `out.env` still holds `old`. `ls -A T` shows no `.jbh-env.*` file. The text `other` and `jbh_admin` are not in stderr |
| E7 | `git check-ignore jbh.env` | prints `jbh.env`, exit 0 |
| E8 | masked print, old checks: V4 to V7 (the four expected line sets of the archived design), V8, V9, V10, V11, V12 | same results as before the change. Run V4 to V9 only through the masked mode |
| E9 | `U sh ./local-swap-env.sh --write-all` (no file); `U sh ./local-swap-env.sh --write-all /nonexistent-dir/x.env` | exit 1 both. stdout empty. stderr one short line: usage in the first, the folder name in the second. No file created |
| E10 | guard: `grep -nE 'set -x\|/tmp/\|echo .*json' local-swap-env.sh` and `grep -c mktemp local-swap-env.sh` | first: no match. second: `1` |
| E11 | `grep -nE 'DB_PORT\|OTEL_\|<POSTGRES' local.mk`; `git diff --stat main -- compose.yaml compose.local.yaml .env.example .env.local.example Makefile README.md DEPLOY.md .github` | no output from either |
| E12 | `grep -n 'jbh.env' LOCAL.md CLAUDE.md .gitignore`; `grep -n 'ln -s' LOCAL.md` | `LOCAL.md` has the path and the steps; `CLAUDE.md` and `.gitignore` have `jbh.env`; `ln -s` appears for both `jbh-personal-finance` and `jbh-notification` |

E4 expected `S/jbh.env` (33 lines, values from `.env.local.example`; `change-me` is the example password and JWT secret; no `SPRING_PROFILES_ACTIVE`):
```
AZURE_DI_API_KEY=
AZURE_DI_ENDPOINT=
AZURE_DI_PAGES_PER_REQUEST=2
CONSUL_DISCOVERY_HOSTNAME=host.docker.internal
CONSUL_HEALTH_CHECK_HOST=host.docker.internal
CONSUL_HOST=localhost
CONSUL_PREFER_IP=false
CORS_ALLOWED_ORIGINS=http://localhost:8100
DATABASE_PASSWORD=change-me
DATABASE_URL=jdbc:postgresql://localhost:5433/jbh_finance
DATABASE_USERNAME=jbh_admin
DB_HOST=localhost
DB_NAME=jbh
DB_PORT=5433
DB_USERNAME=jbh_admin
GEMINI_API_KEY=
GMAIL_APP_PASSWORD=
GMAIL_FROM=
GMAIL_HOST=smtp.gmail.com
GMAIL_PORT=465
GMAIL_USERNAME=
GOOGLE_CLIENT_IDS=
JBH_ADMIN_PASS=change-me
JBH_ENV=local
JBH_FRONTEND_URL=http://localhost:8100
JBH_GATEWAY_URL=http://localhost:8080
JBH_JWT_SECRET=change-me
JEV_API_KEY=
OPENROUTER_API_KEY=
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14317
OTEL_SDK_DISABLED=false
STATEMENT_LLM=openrouter
STATEMENT_TEXT_SOURCE=pdfbox
```
These are the union of the archived V4 to V7 sets (56 lines), unmasked, minus the one `SPRING_PROFILES_ACTIVE=local` line, with equal keys joined (`JBH_ENV`, `OTEL_*`, `CONSUL_*`, `DATABASE_*`, `JBH_GATEWAY_URL`, `JBH_JWT_SECRET`).
If the Compose CLI renders a value with another type (for example a number), compare after `sort`; the line set is what the design fixes.
The example file's `change-me` values are public placeholders, so printing this expected file in a report is fine. Never print an unmasked run that used real shell secrets (E5 files stay in scratch; delete `S` after the checks).

## Risks / Trade-offs

- The file is a plain-text secret on disk: mode 600, git-ignored, atomic, and the docs say so. A Quarkus symlink widens the exposure to another repo's folder; the docs warn to check its `.gitignore`.
- A key that gets different values in two services in the future stops the command with a clear message. The fix is in `compose.local.yaml` or an exclusion (D2), not in this script.
- Union means a service sees keys of the other services (for example `JBH_JWT_SECRET` in `jbh-notification`). Harmless: each service reads only the keys it knows. `SPRING_PROFILES_ACTIVE` is the one key that would change behavior, so it is excluded.
- `CONSUL_PREFER_IP=false` and `CONSUL_HEALTH_CHECK_HOST` reach `jbh-iam` and `jbh-gateway` too. Spring reads neither name today. Accepted.
- Needs `jq` and Compose v2, as before.
