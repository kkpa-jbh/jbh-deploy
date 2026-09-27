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
| `jbh.caddy` | Site file Magus's Caddy imports from `/etc/caddy/sites/`. |
| `.env.example` | Every variable, with placeholders. The real `.env` exists only on the VPS. |
| `Makefile` | `network`, `up`, `deploy s=<svc>`, `caddy-install`, `consul-tunnel`, `db-tunnel`, `backup`, `config`. |
| `initdb/` | First-start SQL: `jbh_finance`, its schemas, `pgcrypto`, time zone. |
| `backup-db.sh` | Daily `pg_dump` of both databases. |

## Rules

- **Never add `ports:`** to a service. Docker-published ports bypass `ufw`, and Magus's Caddy owns 80/443.
- **Caddy: validate, then reload** (`make caddy-install`). Never restart Magus's Caddy.
- **Never commit `.env`** or real secret values. Add every new variable to `.env.example`.
- **Service names are Consul hostnames.** Renaming a service also changes `CONSUL_DISCOVERY_HOSTNAME`, `jbh.caddy`
  and `JBH_GATEWAY_URL`.
- **`edge` subnet `10.231.0.0/24`** must match `JBH_TRUSTED_PROXIES`, or the rate limit breaks.
- **Static checks only:** `docker compose --env-file .env.example -f compose.yaml config -q`. Never `up` from a laptop.

## System map sync

Update `README.md` in the same task when a change touches: gateway routes or public paths, a port, a Consul name,
a `/jbh-api/...` prefix, a call through `jbh-gateway-client`, shared contracts, the build order, the app's API base URL,
or anything in this repo's compose, Caddy site or env vars.
