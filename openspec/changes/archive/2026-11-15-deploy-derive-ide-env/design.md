## Context

`make local-swap s=<service>` stops one container and prints the env vars for an IDE run. Today the values sit in four places:
`compose.local.yaml`, the echo lines and `case` block of `local.mk`, the table in `LOCAL.md`, and the OTLP block in `LOCAL.md`.
The user decided on "one source": `compose.local.yaml` is the only place where a backend's env vars are written.
This change replaces D10 of the archived `deploy-add-local-pg-monitor` (one more echo line to keep make and `LOCAL.md` equal). The script now is the one source.
Scope: shell, make and docs only. No database change. Unit tests: excluded by the user, so there is no test blueprint.

## Decisions

### D1. One source: the script reads compose
`local-swap-env.sh <service>` (repo root) renders `docker compose --env-file "$LOCAL_ENV_FILE" -f compose.local.yaml config --format json`
and prints `.services[<service>].environment`, one `KEY=value` per line, sorted by key (compose JSON key order is not a promise; sorting makes the output stable and testable).
Rejected: a per-service list in the script (a second copy of compose); `docker inspect` (needs a running container, and the container is stopped).

### D2. Translation is in the script, with a comment per rule
The compose values point at Docker names. An IDE on the Mac needs Mac addresses. Rules (jq):

| Rule | Why |
|------|-----|
| value contains `jbh-alloy:4317` -> `localhost:14317` | Alloy publishes OTLP on 14317 (the LGTM owns 4317) |
| value contains `jbh-postgres:5432` -> `localhost:5433` | the Postgres container publishes 5433 (the Mac Postgres owns 5432) |
| value contains `host.docker.internal:8080` -> `localhost:8080` | the gateway port is published; no `/etc/hosts` need for the URL |
| `DB_HOST=jbh-postgres` -> `DB_HOST=localhost`, add `DB_PORT=5433` | IAM has host and port in two keys, so the map cannot do it |
| `CONSUL_HOST=jbh-consul` -> `localhost` | Consul publishes 8500 |
| `CONSUL_DISCOVERY_HOSTNAME` unchanged | every service registers `host.docker.internal` on purpose (LOCAL.md "How it works") |

Whole-key rules run first, then the host:port map on the values.
Rejected: one generic `jbh-* -> localhost` regex. It would also rewrite `CONSUL_DISCOVERY_HOSTNAME`-like values and hide the port mapping.

### D3. Secret masking by key name, inside the jq filter
A non-empty value is printed as `<from .env.local>` when its key matches `SECRET|PASSWORD|PASS|API_KEY|TOKEN`, or is in one short explicit list in the script (`EXTRA_SECRET_KEYS`, empty today).
An empty value prints empty (so `GEMINI_API_KEY=` shows that the key is unset). Matching is on the key, case sensitive (compose keys are upper case).
Keys that match today: `JBH_ADMIN_PASS`, `JBH_JWT_SECRET`, `DATABASE_PASSWORD`, `GMAIL_APP_PASSWORD`, `AZURE_DI_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`, `JEV_API_KEY`.
`DB_USERNAME` and `DATABASE_USERNAME` are not secrets by the rule; they print as rendered.
Rejected: print real values (LOCAL.md would tell users to copy them anyway, but a terminal log or a screen share leaks them); mask by value (cannot know what a secret looks like).

### D4. The raw compose JSON never leaves the script (binding)
The user's shell profile exports `JBH_JWT_SECRET`, `GEMINI_API_KEY`, `POSTGRES_USER` and `POSTGRES_PASSWORD`. Shell values win over the env file, so `docker compose config` renders real secrets.
So the script:
- masks inside the jq filter: the only thing jq prints is the final `KEY=value` lines;
- keeps the JSON in a shell variable only: no temp file, no `set -x`, no `echo "$json"`, no debug output;
- sends `docker compose` stderr and `jq` stderr to `/dev/null` (jq error text can quote a value) and prints its own short message on failure, for example `local-swap-env.sh: docker compose config failed (check: docker compose --env-file .env.local -f compose.local.yaml config -q)`;
- passes the service name and the extra key list to jq with `--arg`, never in the filter text.
Rejected: a pipe `docker compose ... | jq` (POSIX sh has no `pipefail`, so a compose error would be lost).

### D5. Env file override, fail-fast checks
`LOCAL_ENV_FILE` (default `.env.local`) is the env file. A test can use `.env.local.example`.
Order of checks, each prints one short line to stderr and exits 1: argument is one of the four services; `docker` on the `PATH` (message names `docker`); `jq` on the `PATH` (names `jq`); env file exists (names the file); compose renders; jq succeeds.
POSIX sh, `set -eu`, `sh -n` clean. The script has no side effect: it never starts or stops a container.

### D6. `make local-swap` order: render, stop, print
Recipe: check `s` and the swappable list (as today); `vars="$$(sh ./local-swap-env.sh $(s))" || exit 1`; then `$(LOCAL_COMPOSE) stop $(s)`; then print a header, `$$vars`, and the existing last line (Consul address and `make local-restore`).
Why this order: if `jq` is missing the user gets the error before the container stops. The output is already masked (D4), so holding it in a make shell variable is safe.
The echo lines for `CONSUL_DISCOVERY_HOSTNAME`, `OTEL_*`, the `case` block and the `<POSTGRES_USER>` placeholders go away. `LOCAL_SWAPPABLE` stays (it is the make-side check; the script has its own allow-list, one reason to change each: make validates the command, the script validates its input).

### D7. Hints that are not env vars
| Old hint | Decision | Why |
|----------|----------|-----|
| IAM "Profile: local" | dropped | `SPRING_PROFILES_ACTIVE=local` is now printed as an env var |
| `CONSUL_HEALTH_CHECK_HOST` Quarkus note | dropped | the key is in compose, so it is printed (`host.docker.internal`); the note was only there because the old list lacked it |
| Optional `GMAIL_*` and `JBH_FRONTEND_URL` | dropped | all are in compose, so printed (`GMAIL_*` empty by default) |
| "Consul is at localhost:8500 ... Undo with make local-restore" | kept in `local.mk` | not an env var; it is one line and tells how to undo |
| "401 if `JBH_JWT_SECRET` differs" | kept in `LOCAL.md` (one line) | the masked output says "from .env.local"; the reader must know the value must be equal |

### D8. LOCAL.md keeps only what make cannot print
Remove: the "Env vars for a service you run from the IDE" table and the three-line OTLP block in "A service run from the IDE (c)".
Keep and shorten: step 1 of "Swap one service" says `make local-swap s=<service>` prints the env vars (secrets show as `<from .env.local>`: copy them from `.env.local`); a short note why the ports differ (container 5432 / 4317, Mac 5433 / 14317, because the Mac Postgres and the LGTM own the defaults); the 401 line; the Alloy metrics note. The ports table stays.
`README.md` is not changed: it only says `make local-swap s=<service>` and port 14317, both still true.

### D9. Docs and specs
`CLAUDE.md` files table gets `local-swap-env.sh` in the local-stack row. Delta specs: new `local-swap-env`; MODIFIED `deploy-docs` ("Docs describe the local Alloy setup": LOCAL.md no longer gives the IDE var block) and `notification-service-deploy` ("Local compose runs jbh-notification": the swap scenario now states the printed lines).

## Responsibilities

- `local-swap-env.sh` (new): renders one service's compose env as IDE values (translate and mask). Changes when the local stack's hostnames or ports, or the secret rule, change.
- `local.mk` `local-swap`: validates the service name, stops the container, calls the script and prints its output. Changes when the swap flow changes.
- `LOCAL.md`: explains the swap and why the ports differ. Changes when the workflow or the ports change.
- `compose.local.yaml`: unchanged. Stays the one place for env var values.

Script functions (each under 40 lines, cyclomatic well under 10): `fail msg`, `check_args`, `check_tools_and_file`, `render_json`, `to_ide_lines` (holds the jq filter, passed with `--arg`). The jq filter is one string with one `def` per rule (`secret`, `host`) and a `reduce`-free pipeline, so no branch nests deeper than 2.

## Concurrency

none. One short-lived process per call. It reads files and runs `docker compose config` (read only); it starts nothing and shares no state. Two runs at once give the same output.

## Database

No change. No table, column, index, migration or volume change. The Design-Gate `database` does not apply.

## Test contract (checks, no unit tests)

Unit tests: excluded by the user. The leader runs these static checks. None starts a container.
`U` below is: `env -u JBH_JWT_SECRET -u GEMINI_API_KEY -u POSTGRES_USER -u POSTGRES_PASSWORD LOCAL_ENV_FILE=.env.local.example`.

| ID | Command | Expected |
|----|---------|----------|
| V1 | `sh -n local-swap-env.sh` | exit 0, no output |
| V2 | `make -n local-swap s=jbh-iam` | exit 0. Output has `sh ./local-swap-env.sh jbh-iam` and `stop jbh-iam`; has no `case` and no `<POSTGRES_USER>` |
| V3 | `docker compose --env-file .env.example -f compose.yaml config -q && docker compose --env-file .env.local.example -f compose.local.yaml config -q` | exit 0 |
| V4 | `U sh ./local-swap-env.sh jbh-iam` | exactly the 15 lines of V4 below, exit 0 |
| V5 | same, `jbh-personal-finance` | exactly the 19 lines of V5 below |
| V6 | same, `jbh-notification` | exactly the 16 lines of V6 below |
| V7 | same, `jbh-gateway` | exactly the 6 lines of V7 below |
| V8 | negative: `U sh ./local-swap-env.sh <svc> \| grep -E '^[A-Z_]*(SECRET\|PASSWORD\|PASS\|API_KEY\|TOKEN)[A-Z_]*=' \| grep -vE '=(<from \.env\.local>)?$'` for each of the 4 services | no output (no secret key holds an unmasked value) |
| V9 | canary: `LOCAL_ENV_FILE=.env.local.example JBH_JWT_SECRET=canary-jwt POSTGRES_PASSWORD=canary-pg GEMINI_API_KEY=canary-gem sh ./local-swap-env.sh jbh-iam \| grep -c canary` and the same for `jbh-personal-finance` | prints `0` for both (grep exit 1 is fine). Real secrets in the shell never show |
| V10 | `LOCAL_ENV_FILE=.env.local.example sh ./local-swap-env.sh jbh-postgres`; same with no argument | stdout empty, stderr one short line, exit non-zero |
| V11 | `LOCAL_ENV_FILE=/nonexistent sh ./local-swap-env.sh jbh-iam` | stdout empty, stderr names the file, exit non-zero |
| V12 | `PATH=/usr/bin:/bin /bin/sh ./local-swap-env.sh jbh-iam` (docker and jq are not there) | stderr names `docker` or `jq`, exit non-zero |
| V13 | raw JSON guard: `grep -nE 'set -x\|mktemp\|/tmp/\|echo .*json' local-swap-env.sh` | no match. `$json` feeds `jq` only by `printf '%s' "$json" \| jq`. Run V4 with `2>&1 >/dev/null` too: no output |
| V14 | `grep -nE 'DB_PORT\|OTEL_\|<POSTGRES' local.mk`; and `grep -n 'JBH_ADMIN_PASS\|DATABASE_PASSWORD' LOCAL.md` | no match in either: no env var value stays in `local.mk` or `LOCAL.md` |
| V15 | `git diff --stat main -- compose.yaml compose.local.yaml .env.local.example .env.example Makefile README.md .github` | no output |

Do not print an unmasked run. Run V4 to V9 only through the masked script. Never run `docker compose config` without `-q` in a shell that holds the real secrets.

V4, `jbh-iam` (15 lines):
```
CONSUL_DISCOVERY_HOSTNAME=host.docker.internal
CONSUL_HOST=localhost
CORS_ALLOWED_ORIGINS=http://localhost:8100
DB_HOST=localhost
DB_NAME=jbh
DB_PORT=5433
DB_USERNAME=jbh_admin
GOOGLE_CLIENT_IDS=
JBH_ADMIN_PASS=<from .env.local>
JBH_ENV=local
JBH_GATEWAY_URL=http://localhost:8080
JBH_JWT_SECRET=<from .env.local>
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14317
OTEL_SDK_DISABLED=false
SPRING_PROFILES_ACTIVE=local
```
V5, `jbh-personal-finance` (19 lines):
```
AZURE_DI_API_KEY=
AZURE_DI_ENDPOINT=
AZURE_DI_PAGES_PER_REQUEST=2
CONSUL_DISCOVERY_HOSTNAME=host.docker.internal
CONSUL_HEALTH_CHECK_HOST=host.docker.internal
CONSUL_HOST=localhost
CONSUL_PREFER_IP=false
DATABASE_PASSWORD=<from .env.local>
DATABASE_URL=jdbc:postgresql://localhost:5433/jbh_finance
DATABASE_USERNAME=jbh_admin
GEMINI_API_KEY=
JBH_ENV=local
JBH_GATEWAY_URL=http://localhost:8080
JEV_API_KEY=
OPENROUTER_API_KEY=
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14317
OTEL_SDK_DISABLED=false
STATEMENT_LLM=openrouter
STATEMENT_TEXT_SOURCE=pdfbox
```
V6, `jbh-notification` (16 lines):
```
CONSUL_DISCOVERY_HOSTNAME=host.docker.internal
CONSUL_HEALTH_CHECK_HOST=host.docker.internal
CONSUL_HOST=localhost
CONSUL_PREFER_IP=false
DATABASE_PASSWORD=<from .env.local>
DATABASE_URL=jdbc:postgresql://localhost:5433/jbh_finance
DATABASE_USERNAME=jbh_admin
GMAIL_APP_PASSWORD=
GMAIL_FROM=
GMAIL_HOST=smtp.gmail.com
GMAIL_PORT=465
GMAIL_USERNAME=
JBH_ENV=local
JBH_FRONTEND_URL=http://localhost:8100
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14317
OTEL_SDK_DISABLED=false
```
V7, `jbh-gateway` (6 lines):
```
CONSUL_DISCOVERY_HOSTNAME=host.docker.internal
CONSUL_HOST=localhost
JBH_ENV=local
JBH_JWT_SECRET=<from .env.local>
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14317
OTEL_SDK_DISABLED=false
```
Note: the example file has `POSTGRES_PASSWORD=change-me`, so with the canary unset the masked lines come from the key rule, not from an empty value. If the docker CLI orders or types a value differently (for example a number), compare after `sort`; the line set is what the design fixes.

## Risks / Trade-offs

- Needs `jq` and a Compose that supports `config --format json` (Compose v2). Both are named in the error. Accepted by the user.
- The key rule can hide a harmless key (for example a new `*_PASS_*` name) or miss an odd one; the explicit list covers the miss. An over-masked key shows `<from .env.local>`, which is safe.
- Printing `DB_USERNAME`/`DATABASE_USERNAME` as rendered shows the real Postgres user when the shell exports `POSTGRES_USER`. It is not a secret by the user's rule.
- A new compose host:port that is not in the map prints as the Docker name. The map is short and commented, so it is the one place to add a line.
