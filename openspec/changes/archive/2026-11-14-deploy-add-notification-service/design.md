## Context

Today finance runs the notification module and the email settings. After JBH-74, `jbh-notification` is its own
container. Its only caller is `jbh-iam`, through the gateway. The gateway route `/jbh-api/notifications/**` moves to
`lb://jbh-notification` (JBH-74 section 6, another repo). Caddy still answers `404` from the internet for that path.

Verified facts:

- `JBH_FRONTEND_URL` is used in finance only by the notification module. So it moves fully to `jbh-notification`.
  `jbh-iam` also reads it, for `CORS_ALLOWED_ORIGINS` (`${JBH_FRONTEND_URL:-...}` in `compose.yaml`). The `.env` name does not change.
- `jbh-notification` reads `DATABASE_URL`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `CONSUL_*`, `GMAIL_*`,
  `JBH_FRONTEND_URL`. It serves `/q/health` and `/q/metrics` on 7778. Its Consul name is fixed in the app.
- The `notifications` schema already exists in `jbh_finance` (`initdb/`). The service continues the Liquibase history there.

## Decisions

### D1. Service block mirrors `jbh-personal-finance`

Same shape as finance in `compose.yaml`: `restart: unless-stopped`, `logging: *default-logging`, `depends_on`
`jbh-postgres` (healthy) and `jbh-consul` (started), healthcheck with `wget`, `security_opt: no-new-privileges:true`,
`cap_drop: ALL`, `read_only: true`, `tmpfs: /tmp`. Differences:

| Item | Value |
|------|-------|
| image | `ghcr.io/kkpa-jbh/jbh-notification:${JBH_NOTIFICATION_TAG:?set JBH_NOTIFICATION_TAG in .env}` |
| env | `DATABASE_URL: jdbc:postgresql://jbh-postgres:5432/jbh_finance`, `DATABASE_USERNAME: ${POSTGRES_USER:-jbh_admin}`, `DATABASE_PASSWORD: ${POSTGRES_PASSWORD}`, `CONSUL_HOST: jbh-consul`, `CONSUL_PREFER_IP: "true"`, `JBH_FRONTEND_URL: ${JBH_FRONTEND_URL:-https://jbh.usemagus.cloud}`, `GMAIL_HOST`, `GMAIL_PORT`, `GMAIL_USERNAME`, `GMAIL_APP_PASSWORD`, `GMAIL_FROM` (same defaults and `:?` checks as finance has today), `JAVA_OPTS: -Xmx${NOTIFICATION_XMX:-192m}` |
| no `JBH_GATEWAY_URL` | The service calls nobody. |
| healthcheck | `wget -q -O /dev/null http://localhost:7778/q/health`, interval 15s, timeout 5s, retries 5, start_period 60s |
| networks | `jbh-private` only (no `edge`, no `expose`, no `ports`) |
| limits | `cpus: "${NOTIFICATION_CPU_LIMIT:-0.5}"`, `memory: ${NOTIFICATION_MEM_LIMIT:-384M}` |

Why `CONSUL_PREFER_IP: "true"`: like finance, the service is only on `jbh-private`, so the container IP is the right Consul address.
Why no `CONSUL_DISCOVERY_HOSTNAME`: finance does not set it in `compose.yaml`; the same Quarkus Consul code runs here.
Rejected: putting the service on `edge`. Nothing outside needs it, and Caddy blocks the path anyway.

### D2. Finance loses the email settings

`JBH_FRONTEND_URL` and `GMAIL_HOST`, `GMAIL_PORT`, `GMAIL_USERNAME`, `GMAIL_APP_PASSWORD`, `GMAIL_FROM` are removed from
`jbh-personal-finance` in both compose files. In `compose.yaml` the `:?` guards now sit on `jbh-notification`, so a
missing Gmail variable stops that service, not finance. The comment in the `networks:` block ("finance for SMTP and for
the Gemini and Jev APIs") becomes "notification for SMTP, finance for the Gemini and Jev APIs". The header comments of
`compose.yaml` (network line, memory sum) also change.

### D3. Local compose

`compose.local.yaml` gets `jbh-notification`: `image: ghcr.io/kkpa-jbh/jbh-notification:latest`, `pull_policy: always`, `<<: *app-host`,
`DATABASE_*` as finance, `CONSUL_HOST: jbh-consul`, `CONSUL_PREFER_IP: "false"`, `CONSUL_DISCOVERY_HOSTNAME: host.docker.internal`,
`CONSUL_HEALTH_CHECK_HOST: host.docker.internal`, `JBH_FRONTEND_URL: http://localhost:8100`, `GMAIL_*` with the empty `:-` defaults
finance has today, `ports: "7778:7778"`, the same `depends_on`, and a healthcheck on 7778. No `JBH_GATEWAY_URL`.

### D4. Fifth app service in the service lists

`ci-deploy.sh` (`case "$service"` gets `jbh-notification) tag_var=JBH_NOTIFICATION_TAG ;;`; the `refuse` message and the header
text list 5 services), `.github/workflows/deploy.yml` (`options:` list) and the `Makefile` comment ("Only the 5 app services") change together.
The list stays strict: never `jbh-postgres` or `jbh-consul`. The tag check (40-character hex SHA, no `eval`) does not change.
`local.mk`: `LOCAL_SWAPPABLE` gets `jbh-notification`, and the `case` that prints IDE env vars gets a `jbh-notification)` branch:
`DATABASE_URL=jdbc:postgresql://localhost:5433/jbh_finance DATABASE_USERNAME=<POSTGRES_USER> DATABASE_PASSWORD=<POSTGRES_PASSWORD>`,
then a note that the Gmail variables and `JBH_FRONTEND_URL=http://localhost:8100` are optional.
`.github/workflows/deploy.yml` already has step comments (commit `7aa7041`, not from this change). Add only the option line.

### D5. Env files

`.env.example`: add `JBH_NOTIFICATION_TAG=latest` after `JBH_FINANCE_TAG`; rename the comment of the Gmail block to
`# --- Email (jbh-notification) ---` (values unchanged, `JBH_FRONTEND_URL` stays in it, and its comment says IAM reads it for CORS too);
add `NOTIFICATION_CPU_LIMIT=0.5`, `NOTIFICATION_MEM_LIMIT=384M`, `NOTIFICATION_XMX=192m`; change "total about 2.9 GB" to "about 3.3 GB";
the Postgres comment lists `jbh-notification` as a user. `.env.local.example`: only the comment label changes
(`# --- Email (jbh-notification) ---`).
Memory sum: 512 + 256 + 768 + 768 + 512 + 64 + 384 = 3264M, about 3.3 GB. `-Xmx192m` is half of 384M, the same ratio as finance (384m of 768M).

### D6. Release order (docs)

`DEPLOY.md` gets a section for this move (§2.6), and `README.md` "Production" a short pointer:

1. Put `JBH_NOTIFICATION_TAG` in the VPS `.env`. Deploy `jbh-notification` first. Wait until it is healthy in Consul.
   Before that, the new gateway route answers `503`.
2. `jbh-gateway` (route to `jbh-notification`) and `jbh-personal-finance` (no notification module) then deploy in any order.
   The gateway routes to one service at a time, so no email is sent twice.
3. Until finance is deployed without its notification module, both services run the same Liquibase changelog on schema
   `notifications`. Do not change that changelog before then.

`DEPLOY.md` §2.4 "Several services at once" becomes: `jbh-notification` → `jbh-iam` → `jbh-personal-finance` → `jbh-gateway` → `jbh-web`.

### D7. AWS

User decision: the AWS stack sends no email. Remove `GMAIL_USERNAME`, `GMAIL_APP_PASSWORD`, `GMAIL_FROM` (Secrets), `JBH_FRONTEND_URL` (Environment),
the `FrontendUrl` parameter (no other use; checked with grep) and the `GMAIL_*` mention in the `AppSecretArn` description.
`aws/README.md`: remove the three `GMAIL_*` lines from the secret JSON example, and add one line: "This stack sends no email: it runs no
notification service." The ALB rule still holds (it forwards only `/jbh-api/finance/*` and `/jbh-api/preferences/*`, so
`/jbh-api/notifications/*` answers `404`), but the reason changes: finance has no notification endpoint any more. Reword the note to say that,
in `aws/README.md` and in the comment at the top of `finance-fargate.yaml` (line 12). No AWS notification service is added.

### D8. Docs

- `README.md`: projects table (finance role loses "notifications"; add `jbh-notification` port 7778 and a `jbh-commons-lib` library row); mermaid graph
  (`gw -->|lb://jbh-notification| nt[jbh-notification :7778]`, `nt` registers in Consul, `nt --> db2`, `iam` calls the gateway as before);
  route table (`/jbh-api/notifications/**` → `jbh-notification`); endpoint prefix table (notifications row moves to `jbh-notification`);
  section 3 (Consul names: four services register); section 4 table (`jbh-iam` → `jbh-notification`) and circuit breaker text; section 6 databases (add
  `jbh-notification`: `jbh_finance`, schema `notifications`); build dependencies and CI order (commons → contracts → client → services; contracts now come from `jbh-notification`);
  package access (repos that need `PACKAGES_READ_TOKEN`: `jbh-gateway-client`, `jbh-iam`, `jbh-personal-finance`, `jbh-notification`); "Why packages" (Maven packages: `jbh-commons-lib`, `jbh-notification-contracts`, `jbh-gateway-client`);
  local start order (add `jbh-notification` port 7778); Production (network text, service names, memory note about 3.3 GB, env table: finance loses `JBH_FRONTEND_URL` and `GMAIL_*`, new row for `jbh-notification`,
  "only the 4 app services" becomes 5, release order pointer); remove the "Build cycle" known gap. Update every other mention of `jbh-personal-finance (notifications)`.
- `CI.md`: remove `publish-contracts` from `jbh-personal-finance` (table row, mermaid node, section, order step). Add `jbh-commons-lib` rows `CI` (`ci.yml`: pull requests into `main`, by hand; `mvn -B verify`;
  publishes nothing; a new push to the same PR cancels the older run) and `Publish` (`publish.yml`: push to `main`, by hand; `mvn -B -s .github/maven-settings.xml -DskipTests` plus the Maven deploy goal; publishes Maven `jbh-commons-lib`;
  needs only `GITHUB_TOKEN`). Add `jbh-notification` rows `Image` (`image.yml`: push to `main`, by hand; builds `-pl jbh-notification-app -am`, pushes `ghcr.io/kkpa-jbh/jbh-notification` with the SHA and `latest`, keeps the 2 newest)
  and `Publish notification contracts` (`publish.yml`: push to `main` when `jbh-notification-contracts/**` or `pom.xml` changed, by hand; Maven `jbh-notification-contracts` and its parent POM).
  Update: `Image` section (5 service repos; `jbh-notification` build line; it reads `jbh-commons-lib` from GitHub Packages), `Deploy` section (5 services), "Order for shared libraries"
  (`jbh-commons-lib` `Publish` → `jbh-notification` `Publish notification contracts` → `jbh-gateway-client` `Publish` → `Image` of `jbh-iam`, `jbh-personal-finance`, `jbh-notification`), the `PACKAGES_READ_TOKEN` list (add `jbh-notification`; renew in all four repos),
  "Pull requests" (`jbh-commons-lib` also checks pull requests with `CI`), "What CI does not do" (`jbh-notification` runs no tests in CI), and the short-version bullet "Only `jbh-personal-finance` runs tests" (now: also `jbh-commons-lib` runs `mvn verify` on PRs).
  Facts come from the real files in `../jbh-commons-lib/.github/workflows/` and `../jbh-notification/.github/workflows/`.
  Branch protection ("Pull requests" section): all 8 JBH repos have the ruleset `protect-main` active (checked on GitHub by
  jbh-leader, 2026-11-14), so a direct push to `main` is rejected everywhere. The "`main` is protected in ..." sentence and the
  line "`jbh-deploy` and `jbh-gateway-client` have no protection: you still push to `main` there." (from commit `97afc12`) are
  replaced by: "All JBH repos have the ruleset `protect-main`." Name no exception. Do not mention `jbh-discovery-nexus` (retired).
  `jbh-notification` has a third workflow, `CI` (`.github/workflows/ci.yml`, job `verify`; pull requests into `main`, by hand; publishes
  nothing). Add it to the `jbh-notification` rows, next to `Publish notification contracts` and `Image`. Required check: `verify` is a
  required status check in the `protect-main` ruleset of `jbh-notification` and `jbh-commons-lib` (since 2026-11-14; checked with `gh api`),
  so a red PR cannot merge there. The line "No check is required yet, so a red `CI Pipeline` does not block a merge." becomes: no check is
  required in the other repos; in `jbh-notification` and `jbh-commons-lib`, `verify` is required.
- Base: the `CI.md`, `LOCAL.md`, `DEPLOY.md` and `README.md` edits start from the branch head, which already has commit `97afc12`
  (local Consul moved to `kkpa-docker-lab`, `jbh-discovery-nexus` retired). Keep those changes.
- `LOCAL.md`: port table (`jbh-notification` 7778), health check list in "Daily use", swap list, IDE env table row; "mail keys can stay empty" stays true.
- `DEPLOY.md`: section 0 (5 images, token repo list), "Why the key is safe" (5 services), §2.1 table (add `jbh-notification` `Image` and `Publish notification contracts`, `jbh-commons-lib` `Publish`; remove the finance contracts row), §2.2 service list, §2.3 (library order, as in `CI.md`), §2.4 (order),
  new §2.6 release order (D6), the "Invitation emails do not arrive" row → `make logs s=jbh-notification`.
- `observability/README.md`: add row `jbh-notification | :7778/q/metrics | service=jbh-notification, env`. The dashboard JSON does not change.

## Test contract (expected values)

No unit tests: this repo has no unit-testable code, and the JBH-74 plan excludes them. There is no test blueprint group.
Verification is static. Expected values:

| # | Check | Expected |
|---|-------|----------|
| V1 | `docker compose --env-file .env.example -f compose.yaml config -q` | exit 0, no output |
| V2 | `docker compose --env-file .env.local.example -f compose.local.yaml config -q` | exit 0, no output |
| V3 | `docker compose --env-file .env.example -f compose.yaml config --services` | 7 services, including `jbh-notification` (postgres, consul, iam, personal-finance, notification, gateway, web) |
| V4 | `config` of `compose.yaml`, service `jbh-notification` | `networks` = `jbh-private` only; no `ports`; no `expose`; image `ghcr.io/kkpa-jbh/jbh-notification:latest`; `JAVA_OPTS` = `-Xmx192m`; memory limit 402653184 (384M); `DATABASE_URL` = `jdbc:postgresql://jbh-postgres:5432/jbh_finance`; `cap_drop` = ALL; `security_opt` = `no-new-privileges:true`; healthcheck URL `http://localhost:7778/q/health` |
| V5 | same output, service `jbh-personal-finance` | no key `GMAIL_*`, no key `JBH_FRONTEND_URL` |
| V6 | same output, service `jbh-notification` | `GMAIL_HOST` = `smtp.gmail.com`, `GMAIL_PORT` = `465`, `GMAIL_USERNAME` = `change-me@gmail.com`, `GMAIL_APP_PASSWORD` = `change-me`, `GMAIL_FROM` = `change-me@gmail.com`, `JBH_FRONTEND_URL` = `https://jbh.usemagus.cloud` |
| V7 | `compose.yaml` with an env file that has no `JBH_NOTIFICATION_TAG` | `config` fails with `set JBH_NOTIFICATION_TAG in .env` |
| V8 | `config` of `compose.local.yaml`, service `jbh-notification` | published port `7778`, `CONSUL_DISCOVERY_HOSTNAME` = `host.docker.internal`; finance has no `GMAIL_*` and no `JBH_FRONTEND_URL` |
| V9 | `grep -n "jbh-notification" ci-deploy.sh .github/workflows/deploy.yml Makefile local.mk` | present in the service lists of `ci-deploy.sh` and `deploy.yml`; both lists hold the same 5 names: `jbh-web`, `jbh-gateway`, `jbh-iam`, `jbh-personal-finance`, `jbh-notification` |
| V10 | `ci-deploy.sh` with `deploy jbh-postgres`, `deploy jbh-consul`, `deploy jbh-notification abc` | each ends with `Refused` (exit 2). Checked by reading; running needs a VPS |
| V11 | `grep -rn "GMAIL" aws/` and `grep -n "FrontendUrl\|JBH_FRONTEND_URL" aws/finance-fargate.yaml` | no match |
| V12 | `grep -n "publish-contracts\|Build cycle" README.md CI.md DEPLOY.md` | no match |
| V13 | `git diff --stat -- jbh.caddy initdb` | empty |
| V14 | `sh -n ci-deploy.sh` | exit 0 |

## Database

No database object is created or changed. No table, column, index, constraint, view or migration. The `notifications`
schema and `pgcrypto` already exist in `jbh_finance` (`initdb/`). `jbh-notification` uses the same database, user and schema as finance did.
No index plan is needed.

## Concurrency

none in code or compose. One operational risk, already accepted by the user in the JBH-74 plan ("Release rules"), with no extra guard:
until `jbh-personal-finance` is deployed without its notification module, finance and `jbh-notification` both run the same Liquibase
changelog (`db/notificationdb-master.xml`) on schema `notifications`. This is safe only while the changelog is identical in both repos.
Guard (documentation only): D6 step 3 tells the operator not to change that changelog before finance is deployed. No task in this change touches the changelog.

## Responsibilities

none. This change adds no class or function. The only logic is one `case` branch in `ci-deploy.sh` and one in `local.mk`.

## Risks / Trade-offs

- A wrong release order gives `503` on `/jbh-api/notifications/**` (invitation emails fail, nothing is lost). D6 documents the order.
- Memory: +384M on a VPS that Magus shares. The jbh stack stays about 3.3 GB of 7.7 GB (Magus about 2 GB).
- The `:?` guards on `GMAIL_*` move to `jbh-notification`: `make up` still fails fast when they are missing, as before.
- `compose.yaml` needs `JBH_NOTIFICATION_TAG` in the VPS `.env`, or every `make` command that reads compose fails. D6 step 1 covers it.
