## Why

JBH-74 moves `jbh-notification` out of `jbh-personal-finance` into its own Quarkus service and repo
(`kkpa-jbh/jbh-notification`, port 7778, Consul name `jbh-notification`). The new image is on GHCR.
This repo (`jbh-deploy`) must run it, and the docs must match the new layout.
This is section 7 of the JBH-74 system plan. Sections 1–6 happen in other repos and are prerequisites.

## What Changes

- `compose.yaml`: new service `jbh-notification` (image `ghcr.io/kkpa-jbh/jbh-notification:${JBH_NOTIFICATION_TAG}`,
  port 7778, `jbh-private` only, memory limit 384M, `-Xmx192m`, healthcheck `/q/health`, same `jbh_finance` database).
- `compose.yaml` and `compose.local.yaml`: `GMAIL_*` and `JBH_FRONTEND_URL` move from `jbh-personal-finance` to `jbh-notification`.
- `compose.local.yaml`: new service `jbh-notification` (host port 7778, `host.docker.internal` in Consul).
- `.env.example`, `.env.local.example`: new tag and limit variables; the email block is labelled `jbh-notification`.
- `ci-deploy.sh`, `.github/workflows/deploy.yml`, `Makefile`, `local.mk`: `jbh-notification` is the fifth app service
  (tag variable `JBH_NOTIFICATION_TAG`). The two service lists stay equal.
- `aws/finance-fargate.yaml` and `aws/README.md`: remove `GMAIL_*` and `JBH_FRONTEND_URL`. The AWS stack then sends no email.
- `observability/README.md`: add `jbh-notification` to the metrics table.
- Docs: `README.md` (system map), `CI.md`, `LOCAL.md`, `DEPLOY.md` (including the release order).
- **No change:** `jbh.caddy` (the `respond 404` block on `/jbh-api/notifications*` stays), `initdb/`.

## Capabilities

### New Capabilities

- `notification-service-deploy`: how `jbh-notification` runs in `compose.yaml` and `compose.local.yaml`, its env vars,
  its limits, and how `ci-deploy.sh`, the `Deploy` workflow and the Makefile treat it.
- `deploy-docs`: what the system map, CI, local and deploy docs must say after the move, including the release order.

### Modified Capabilities

None. `openspec/specs/` is empty.

## Impact

- Files: `compose.yaml`, `compose.local.yaml`, `.env.example`, `.env.local.example`, `ci-deploy.sh`, `Makefile`, `local.mk`,
  `.github/workflows/deploy.yml`, `aws/finance-fargate.yaml`, `aws/README.md`, `observability/README.md`,
  `README.md`, `CI.md`, `LOCAL.md`, `DEPLOY.md`.
- VPS memory: about 2.9 GB becomes about 3.3 GB for the jbh stack (adds 384M). Magus keeps about 2 GB of 7.7 GB.
- The VPS `.env` needs `JBH_NOTIFICATION_TAG` before the next `make up`. `GMAIL_*` and `JBH_FRONTEND_URL` stay in `.env` (no rename).
- Release order matters (see design.md, D6). A wrong order gives `503` on `/jbh-api/notifications/**` for a short time, nothing worse.

## Non-goals

- No notification service on AWS.
- No change to `jbh.caddy`, `initdb/`, the root `kkpa-jbh/CLAUDE.md`, or Linear.
- No new database object.
- No unit tests: this repo has no unit-testable code, and the JBH-74 plan excludes unit tests.
