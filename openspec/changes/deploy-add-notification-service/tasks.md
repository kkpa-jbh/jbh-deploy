## Test blueprint

No unit tests in this change (no unit-testable code; the JBH-74 plan excludes them). No blueprint group.
Verification is the static checks V1–V14 in design.md "Test contract".

## 1. Compose and env files (module files: compose, env examples)

Depends on: nothing.

- [x] 1.1 `compose.yaml`: add service `jbh-notification` after `jbh-personal-finance` as in design.md D1. Remove `JBH_FRONTEND_URL` and `GMAIL_*` from `jbh-personal-finance`. Update the header comments (private network line, memory sum about 3.3 GB) and the `networks:` comment (D2).
- [x] 1.2 `compose.local.yaml`: add service `jbh-notification` (D3). Remove `JBH_FRONTEND_URL` and `GMAIL_*` from `jbh-personal-finance`.
- [x] 1.3 `.env.example`: add `JBH_NOTIFICATION_TAG=latest`, `NOTIFICATION_CPU_LIMIT=0.5`, `NOTIFICATION_MEM_LIMIT=384M`, `NOTIFICATION_XMX=192m`; relabel the Gmail block; update the total (D5). `.env.local.example`: relabel the Gmail block.

## 2. Deploy lists (ci-deploy.sh, workflow, Makefile, local.mk)

Depends on: nothing. Keep the step comments in `.github/workflows/deploy.yml` (commit `7aa7041`); add only the option line.

- [x] 2.1 `ci-deploy.sh`: add the `jbh-notification) tag_var=JBH_NOTIFICATION_TAG ;;` branch; update the `refuse` message. Keep the rest unchanged (40-character SHA check, no `eval`).
- [x] 2.2 `.github/workflows/deploy.yml`: add `jbh-notification` to the `service` options. The list must equal the one in `ci-deploy.sh`.
- [x] 2.3 `Makefile`: change the comment "Only the 4 app services" to 5.
- [x] 2.4 `local.mk`: add `jbh-notification` to `LOCAL_SWAPPABLE` and a `jbh-notification)` branch to the IDE env `case` (D4).

## 3. AWS and observability

Depends on: nothing.

- [x] 3.1 `aws/finance-fargate.yaml`: remove the three `GMAIL_*` secrets, `JBH_FRONTEND_URL`, parameter `FrontendUrl`, the `GMAIL_*` mention in `AppSecretArn`; reword the comment on line 12 (D7). Keep the ALB rules unchanged.
- [x] 3.2 `aws/README.md`: remove `GMAIL_*` from the secret JSON; add the line "This stack sends no email"; reword the `/jbh-api/notifications/*` note (D7).
- [x] 3.3 `observability/README.md`: add the `jbh-notification` row (`:7778/q/metrics`).

## 4. System map

Depends on: 1 (for the env table values).

- [x] 4.1 `README.md`: every item listed under "README.md" in design.md D8. Remove the "Build cycle" known gap. Add the release-order pointer to `DEPLOY.md` in "Production".

## 5. CI and operator docs

Depends on: 2 (service names). Reads the real workflow files in `../jbh-commons-lib/.github/workflows/` and `../jbh-notification/.github/workflows/`.

- [x] 5.1 `CI.md`: every item listed under "CI.md" in design.md D8.
- [x] 5.2 `LOCAL.md`: port table, health list, swap list, IDE env row (D8).
- [x] 5.3 `DEPLOY.md`: every item listed under "DEPLOY.md" in design.md D8, including new §2.6 with the release order (D6).
- [x] 5.4 `CI.md` "Pull requests": replace the "`main` is protected in ..." sentence and the "no protection" line with "All JBH repos have the ruleset `protect-main`." No exception, no `jbh-discovery-nexus` (D8, branch protection).
- [x] 5.5 `CI.md`: add the `jbh-notification` `CI` workflow (`ci.yml`, job `verify`, pull requests into `main` + by hand) next to its other rows, and state that `verify` is a required status check in `protect-main` of `jbh-notification` and `jbh-commons-lib`; reword "No check is required yet" (D8).

## 6. Static verification (leader runs)

Depends on: 1–5.

- [ ] 6.1 Run `docker compose --env-file .env.example -f compose.yaml config -q` and `docker compose --env-file .env.local.example -f compose.local.yaml config -q`; check V3–V14 from design.md.

Size estimate: 15 files, ~450 changed lines (tests and docs included)
