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
| `compose.local.yaml`, `local.mk`, `local-swap-env.sh`, `.env.local.example`, `LOCAL.md`, `jbh.env` | Local dev stack for a developer machine (`make local-up`; `make local-pg-monitor` prepares an existing Postgres for Alloy; `local-swap-env.sh` prints the IDE env vars for `make local-swap`; `make local-ide-env` writes them for all four services, with real secrets, to `jbh.env`, which is generated and git-ignored). Publishes host ports. Never used on the VPS. |
| `jbh.caddy` | Site file Magus's Caddy imports from `/etc/caddy/sites/`. |
| `.env.example` | Every variable, with placeholders. The real `.env` exists only on the VPS. |
| `Makefile` | `network`, `up`, `deploy s=<svc>`, `rollback s=<svc>`, `caddy-install`, `consul-tunnel`, `db-tunnel`, `backup`, `config`. |
| `initdb/` | First-start SQL: `jbh_finance`, its schemas, `pgcrypto`, time zone. `02-create-monitor-role.sh` runs `initdb/sql/pg-monitor.sql` (the `jbh_monitor` role and `pg_stat_statements`); it skips itself when `JBH_PG_MONITOR_PASSWORD` is empty (the VPS does not pass it). |
| `observability/alloy/` | Grafana Alloy config: `local.alloy` (entry file for the local stack) and `modules/` (`otlp`, `jbh-scrape`, `postgres`). Local only for now; no secret in a file. |
| `observability/grafana/`, `observability/alerts/`, `observability/GUIDE.md`, `observability/VERIFY.md` | Dashboards (JSON, imported by hand in the Grafana UI), alert rules (YAML, created by hand from the files), the beginner guide and the hands-on verification checklist. `observability/README.md` has the import steps. Local only for now. |
| `initdb/sql/pg-monitor.sql` | Shared, re-runnable SQL for the monitor role. In a subfolder, so the Postgres entrypoint does not run it alone. Used by `02-create-monitor-role.sh` and `local-pg-monitor.sh`. |
| `local-pg-monitor.sh` | Local only. Checks `shared_preload_libraries` of an existing Postgres, then runs the shared SQL. Called by `make local-pg-monitor`. Never restarts Postgres. |
| `backup-db.sh` | Daily `pg_dump` of both databases. |
| `local-db.sh` | Local only. `make local-db-backup` / `make local-db-restore d=<dir>`: dumps to and restores from `backups/local/`. Restore takes a safety backup first and restarts only the services it stopped. |
| `ci-deploy.sh` | Deploy or roll back one app service, wait until healthy, roll back by itself on failure. Forced command of the CI deploy key; `make deploy` / `make rollback` call it too. |
| `.github/workflows/deploy.yml` | `Deploy` workflow: SSH to the VPS, runs `ci-deploy.sh`. By hand, or from `jbh-app`'s `Image` (auto-deploy of `jbh-web`). |
| `.github/workflows/multi-arch-image.yml` | Reusable workflow (`on: workflow_call`). Each service's `Image` workflow calls it, pinned to a commit SHA: amd64 + arm64 images, one tag, cleanup (keep 10 tagged). |
| `.github/workflows/ci.yml`, `.github/scripts/install-tool.sh` | PR check: `actionlint`, render + `kubeconform` of `k8s/overlays/local`, `scripts/check-k8s-base.sh`, Kyverno "restricted" Pod Security. Tools at a fixed version and SHA-256. |
| `k8s/`, `k8s.mk`, `LOCAL-K8S.md`, `scripts/k8s-pin.sh`, `scripts/check-k8s-base.sh` | Kubernetes (JBH-86): `base/` (same on every target), `components/postgres/`, `overlays/local/` (k3d), `policies/`, `docs/` (learning guides). `make k8s-up` / `k8s-down` / `k8s-pin`. Local only for now. Rule: `k8s/base/` holds no target-specific value (`k8s/README.md`). |

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
- **Static checks only:** `docker compose --env-file .env.example -f compose.yaml config -q`. Kubernetes: `make k8s-render`, `scripts/check-k8s-base.sh` (never `make k8s-up` from an agent: it starts a cluster). Never `up` `compose.yaml` from a laptop.
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
