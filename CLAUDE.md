# jbh-deploy

Production deploy of the JBH system on the Hostinger VPS, behind Magus's Caddy.
It also holds `README.md`: the system map of all JBH services. The `kkpa-jbh/CLAUDE.md` leader file imports it.

## Files

| File | Role |
|------|------|
| `README.md` | System map (routes, calls, auth, build order, production layout). Single source of truth. |
| `DEPLOY.md` | Operator runbook: every command with the folder to run it in. Update it when a step changes. |
| `CI.md` | GitHub Actions in every repo: triggers, steps, image retention, secrets. Update it when a workflow changes. |
| `compose.yaml` | All jbh services. No host ports. Only `jbh-gateway` and `jbh-web` join `edge`. |
| `compose.local.yaml`, `local.mk`, `.env.local.example`, `LOCAL.md` | Local dev stack for a developer machine (`make local-up`). Publishes host ports. Never used on the VPS. |
| `jbh.caddy` | Site file Magus's Caddy imports from `/etc/caddy/sites/`. |
| `.env.example` | Every variable, with placeholders. The real `.env` exists only on the VPS. |
| `Makefile` | `network`, `up`, `deploy s=<svc>`, `rollback s=<svc>`, `caddy-install`, `consul-tunnel`, `db-tunnel`, `backup`, `config`. |
| `initdb/` | First-start SQL: `jbh_finance`, its schemas, `pgcrypto`, time zone. |
| `backup-db.sh` | Daily `pg_dump` of both databases. |
| `ci-deploy.sh` | Deploy or roll back one app service, wait until healthy, roll back by itself on failure. Forced command of the CI deploy key; `make deploy` / `make rollback` call it too. |
| `.github/workflows/deploy.yml` | `Deploy` workflow: SSH to the VPS, runs `ci-deploy.sh`. By hand, or from `jbh-app`'s `Image` (auto-deploy of `jbh-web`). |

## Rules

- **Never add `ports:`** to a service in `compose.yaml` (`compose.local.yaml` is the only exception). Docker-published ports bypass `ufw`, and Magus's Caddy owns 80/443.
- **Caddy: validate, then reload** (`make caddy-install`). Never restart Magus's Caddy.
- **Never commit `.env`** or real secret values. Add every new variable to `.env.example`.
- **Service names are Consul hostnames.** Renaming a service also changes `CONSUL_DISCOVERY_HOSTNAME`, `jbh.caddy`
  and `JBH_GATEWAY_URL`.
- **`edge` subnet `10.231.0.0/24`** must match `JBH_TRUSTED_PROXIES`, or the rate limit breaks.
- **`ci-deploy.sh` is a security boundary.** The CI key can run nothing else. Keep its service list strict
  (never `jbh-postgres` or `jbh-consul`), accept only a full 40-character hex SHA as tag, never pass the input
  to `eval` or a shell, and keep the list equal to `deploy.yml`.
- **Static checks only:** `docker compose --env-file .env.example -f compose.yaml config -q`. Never `up` `compose.yaml` from a laptop.
  `compose.local.yaml` is for a laptop; check it with `--env-file .env.local.example -f compose.local.yaml config -q`.

## System map sync

Update `README.md` in the same task when a change touches: gateway routes or public paths, a port, a Consul name,
a `/jbh-api/...` prefix, a call through `jbh-gateway-client`, shared contracts, the build order, the app's API base URL,
or anything in this repo's compose, Caddy site or env vars.

## Pipeline config (kkpa-orchestrate-change)

- **Modules-Root:** `.` (one module: the whole repo, `jbh-deploy`)
- **Doc-Pack:** `CLAUDE.md`, `README.md`
- **Complexity-Check:** `docker compose --env-file .env.example -f compose.yaml config -q && docker compose --env-file .env.local.example -f compose.local.yaml config -q`
  (static check only; this repo has no code with real complexity)
- **Design-Gates:** `database`
- **Git-Strategy:** `auto`
