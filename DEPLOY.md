# Deploy guide — jbh.usemagus.cloud

Step by step. Every command says **where** to run it.
Why the setup looks like this: `README.md`, section "Production (Hostinger VPS)".

- **VPS** = SSH session on the Hostinger VPS, as the `magus` user.
- Magus lives in `/home/magus/magus-tesla-api`. This repo goes next to it: `/home/magus/jbh-deploy`.

## 0. What you need first

- [ ] The 4 images exist in GHCR (GitHub → org `kkpa-jbh` → Packages): `jbh-gateway`, `jbh-iam`,
      `jbh-personal-finance`, `jbh-web`. Each repo's `Image` workflow builds one on every push to `main`.
- [ ] A GitHub **classic token** with only `read:packages` (the same one stored as the `PACKAGES_READ_TOKEN`
      secret in `jbh-gateway-client`, `jbh-iam`, `jbh-personal-finance`).
- [ ] The Magus changes are pushed (Caddyfile `import`, `edge` network in `compose.yaml`).
- [ ] The values for `.env`: a Postgres password, a `JWT_SECRET`, the Gmail account and app password.

## 1. First deploy (one time)

| # | Where | Do |
|---|-------|----|
| 1 | Hostinger panel → DNS for `usemagus.cloud` | Add an `A` record: name `jbh`, value = VPS IP. |
| 2 | VPS, any folder | `sudo apt install -y make` (skip if `make --version` works). |
| 3 | VPS, `/home/magus` | `git clone https://github.com/kkpa-jbh/jbh-deploy.git` |
| 4 | VPS, `/home/magus/jbh-deploy` | `make network` — creates the shared network `edge` (subnet `10.231.0.0/24`). |
| 5 | VPS, any folder | `mkdir -p /home/magus/caddy-sites` |
| 6 | VPS, `/home/magus/magus-tesla-api` | `git pull` |
| 7 | VPS, `/home/magus/magus-tesla-api` | `docker compose --project-directory . -f deploy/docker/compose.yaml up -d caddy` |
| 8 | VPS, `/home/magus/magus-tesla-api` | `docker compose --project-directory . -f deploy/docker/compose.yaml exec caddy caddy validate --config /etc/caddy/Caddyfile` — a warning about the empty `sites` folder is fine; an error is not. |
| 9 | Browser | Open the Magus site. It must still work. **Stop here if it does not.** |
| 10 | VPS, `/home/magus/jbh-deploy` | `cp .env.example .env` then `nano .env`. Fill every `change-me`. Generate `JWT_SECRET` with `openssl rand -base64 32`. |
| 11 | VPS, any folder | `docker ps --format '{{.Names}}' \| grep caddy` → put that name in `.env` as `MAGUS_CADDY_CONTAINER`. |
| 12 | VPS, any folder | `docker login ghcr.io -u grug-dev` → paste the `read:packages` token as the password. |
| 13 | VPS, `/home/magus/jbh-deploy` | `make config` — must print `compose.yaml OK`. |
| 14 | VPS, `/home/magus/jbh-deploy` | `make up` |
| 15 | VPS, `/home/magus/jbh-deploy` | `make ps` — repeat until all services are `healthy` (1–2 minutes; the JVMs start slowly). |
| 16 | VPS, `/home/magus/jbh-deploy` | `make caddy-install` — copies `jbh.caddy`, validates, reloads Caddy. |
| 17 | Browser | Open `https://jbh.usemagus.cloud`. The first visit can take a few seconds (certificate). |

### Check it works

- [ ] The app loads with a valid lock icon.
- [ ] Log in. Open a finance page: data loads.
- [ ] Invite a user to a team: the email arrives, and its link opens `https://jbh.usemagus.cloud`.
- [ ] The Magus site still works.
- [ ] From your laptop: `nmap -p- <vps-ip>` shows only 22, 80, 443.
- [ ] Consul: `make consul-tunnel` (VPS, `/home/magus/jbh-deploy`) prints an `ssh -L ...` command.
      Run it **on your laptop**, open http://localhost:8500 — `jbh-iam-service`, `jbh-personal-finance`
      and `API Gateway` are green.
- [ ] VPS: `docker stats --no-stream` — total memory well under 7.7 GB.

## 2. Deploy an update

1. **Laptop:** push to `main` in the service repo. Wait until its `Image` workflow is green.
2. **VPS, `/home/magus/jbh-deploy`:** `make deploy s=<service>` — for example `make deploy s=jbh-gateway`.
   It pulls the new image and restarts only that service.

Service names: `jbh-gateway`, `jbh-iam`, `jbh-personal-finance`, `jbh-web`.

With `JBH_<SERVICE>_TAG=latest` in `.env`, the step above takes the newest image. To pin a version, put the git SHA
of the commit instead (`JBH_IAM_TAG=34bcf39...`, full 40 characters).

## 3. Roll back

1. Find the old commit SHA: GitHub → the repo → Actions → a green `Image` run, or `git log` in the repo.
   Only the **last 5** images are kept (older ones are deleted to stay in the free 500 MB).
2. **VPS, `/home/magus/jbh-deploy`:** set `JBH_<SERVICE>_TAG=<full-sha>` in `.env`.
3. **VPS, `/home/magus/jbh-deploy`:** `make deploy s=<service>`.

## 4. Change the Caddy site

1. Edit `jbh.caddy` in this repo, push, then **VPS, `/home/magus/jbh-deploy`:** `git pull`.
2. **VPS, `/home/magus/jbh-deploy`:** `make caddy-install`.

It validates first and reloads only if valid. **Never restart Magus's Caddy** for a jbh change: a restart with a
bad file stops Caddy, and Magus goes down with it.

## 5. Backups

- **One time, VPS:** `crontab -e`, add:
  `0 3 * * * cd /home/magus/jbh-deploy && ./backup-db.sh >> backups/backup.log 2>&1`
- Dumps land in `/home/magus/jbh-deploy/backups/` (both databases, 14 days kept).
- **Copy them off the VPS** (a backup on the same disk is lost with the VPS). From your **laptop**:
  `scp -r magus@<vps-ip>:/home/magus/jbh-deploy/backups ./jbh-backups`
- Restore one database (**VPS, `/home/magus/jbh-deploy`**, overwrites data):
  `docker compose --env-file .env -f compose.yaml exec -T jbh-postgres sh -c 'pg_restore -U "$POSTGRES_USER" -d jbh --clean' < backups/jbh-<date>.dump`

## 6. When something is wrong

| Symptom | Where / what |
|---------|--------------|
| `502` on jbh.usemagus.cloud | VPS, `/home/magus/jbh-deploy`: `make ps`, then `make logs s=jbh-gateway` (or `jbh-web`). |
| `401` on every API call | `JWT_SECRET` differs between IAM and gateway? It is one value in `.env`; restart both with `make deploy`. |
| API returns `503` / "no instances" | The gateway cannot find a service in Consul. Check the Consul UI (tunnel above) and `make logs s=jbh-iam`. |
| `make up` says `edge` not found | VPS, `/home/magus/jbh-deploy`: `make network`. |
| `docker pull` → `denied` / `unauthorized` | The token expired. Create a new one, `docker login ghcr.io` again, and update `PACKAGES_READ_TOKEN` in the 3 repos. |
| CI: `Could not find artifact com.jbh:...` | `PACKAGES_READ_TOKEN` is missing or expired in that repo. |
| Invitation emails do not arrive | `make logs s=jbh-personal-finance`; check `GMAIL_*` in `.env` (Gmail needs an app password). |

## 7. Limits and cost

- The VPS is already paid. DNS, the HTTPS certificate (Let's Encrypt) and Gmail SMTP are free.
- GitHub Free, private repos: 2,000 Actions minutes and **500 MB package storage + 1 GB download per month**.
  CI keeps only 5 images per service. With the default $0 spending limit, going over makes pushes or pulls fail;
  it does not create a bill. Check usage in GitHub → org settings → Billing.
