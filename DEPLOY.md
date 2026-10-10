# Deploy guide — jbh.usemagus.cloud

Step by step. Every command says **where** to run it.
Why the setup looks like this: `README.md`, section "Production (Hostinger VPS)".

- **VPS** = SSH session on the Hostinger VPS, as the `magus` user.
- Magus lives in `/home/magus/magus-tesla-api`. This repo goes next to it: `/home/magus/jbh-deploy`.

## How a request reaches jbh

Magus and jbh run on the **same VPS** and share **one Caddy** (Magus's). Four steps:

**1. DNS only gives an address.** The `A` record `jbh` says "`jbh.usemagus.cloud` is at the VPS IP".
Magus's domain (`BASE_DOMAIN` in Magus's `.env`) points to the **same IP**. DNS knows nothing about apps.

**2. The browser says which name it wants.** Every HTTPS request carries the typed name (the `Host` header,
and the TLS handshake). So the VPS receives "I want `jbh.usemagus.cloud`" or "I want Magus's domain".

**3. Caddy is the only program on ports 80/443, and it reads that name.** Its config has one site block per name:

```
<Magus BASE_DOMAIN> {        ← Magus's Caddyfile
    → Magus web:8080
}

jbh.usemagus.cloud {         ← jbh.caddy (imported from /etc/caddy/sites/)
    /jbh-api/*       → jbh-gateway:8080
    everything else  → jbh-web:8080
}
```

Caddy picks the block that matches the name, and gets one HTTPS certificate per name.

**4. The jbh block picks the container by path.**

- `https://jbh.usemagus.cloud/` → `jbh-web`: the built `jbh-app` files. The browser loads the app.
- The app then calls `https://jbh.usemagus.cloud/jbh-api/...` → same name, but the path starts with `/jbh-api/`
  → `jbh-gateway` → `jbh-iam` or `jbh-personal-finance`.

```
browser ── jbh.usemagus.cloud ──┐
                                ├──► VPS :443 ── Caddy ──┬─ <Magus domain>      → Magus web
browser ── <Magus domain> ──────┘   (same IP)             └─ jbh.usemagus.cloud  → jbh-web / jbh-gateway
```

**Why one shared Caddy:** only one program can listen on port 443 of a machine, and Magus's Caddy has it. So jbh adds
a site file instead of its own proxy. The Docker network `edge` lets that Caddy reach `jbh-web` and `jbh-gateway`.
IAM, finance, Consul and Postgres stay on the private network `jbh-private`.

**Why three containers can all use port 8080:** `jbh-gateway`, `jbh-web` and Magus's `web` all listen on 8080.
That is fine: each container has its own network space and its own IP, so their ports never clash. Caddy calls them
by name (`jbh-gateway:8080`, `web:8080`), and Docker's DNS gives the right IP. Ports clash only when published on the
**host** (`ports:`), and no jbh service does that — Caddy's 80/443 are the only host ports.

**Check:** Magus's `BASE_DOMAIN` must be Magus's own name, never `jbh.usemagus.cloud`. Two blocks with one name make
`caddy validate` fail (step 16) — and because it validates first, Magus keeps running.

## 0. What you need first

- [ ] The 4 images exist in GHCR (GitHub → org `kkpa-jbh` → Packages): `jbh-gateway`, `jbh-iam`,
      `jbh-personal-finance`, `jbh-web`. Each repo's `Image` workflow builds one on every push to `main`.
- [ ] A GitHub **classic token** with only `read:packages` (the same one stored as the `PACKAGES_READ_TOKEN`
      secret in `jbh-gateway-client`, `jbh-iam`, `jbh-personal-finance`).
- [ ] The Magus changes are pushed (Caddyfile `import`, `edge` network in `compose.yaml`).
- [ ] The values for `.env`: a Postgres password, a `JBH_JWT_SECRET`, the Gmail account and app password.

## 1. First deploy (one time)

| # | Where | Do |
|---|-------|----|
| 1 | Hostinger panel → DNS for `usemagus.cloud` | Add an `A` record: name `jbh`, value = VPS IP. |
| 2 | VPS, any folder | `sudo apt install -y make` (skip if `make --version` works). |
| 3 | VPS, `/home/magus` | `git clone https://github.com/kkpa-jbh/jbh-deploy.git` |
| 4 | VPS, `/home/magus/jbh-deploy` | `make network` — creates the shared network `edge` (subnet `10.231.0.0/24`). |
| 5 | VPS, any folder | `mkdir -p /home/magus/caddy-sites` — **before** step 7, or Docker creates it as `root` and step 16 fails. |
| 6 | VPS, `/home/magus/magus-tesla-api` | `git pull` |
| 7 | VPS, `/home/magus/magus-tesla-api` | `docker compose --project-directory . -f deploy/docker/compose.yaml up -d caddy` |
| 8 | VPS, `/home/magus/magus-tesla-api` | `docker compose --project-directory . -f deploy/docker/compose.yaml exec caddy caddy validate --config /etc/caddy/Caddyfile` — a warning about the empty `sites` folder is fine; an error is not. |
| 9 | Browser | Open the Magus site. It must still work. **Stop here if it does not.** |
| 10 | VPS, `/home/magus/jbh-deploy` | `cp .env.example .env` then `nano .env`. Fill every `change-me`. Generate `JBH_JWT_SECRET` with `openssl rand -base64 32`. |
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

### 1.1 Set up the Deploy button (one time)

The `Deploy` workflow deploys one service from GitHub, without your own SSH session.
Daily use: §2.2. Workflow details: `CI.md`, "Deploy".

#### How it reaches the VPS

It uses plain SSH, like your laptop does. Only the key is different.

```
You click "Run workflow" and pick jbh-web
        │
        ▼
GitHub runner: a temporary Ubuntu machine, deleted after the run
        │  ssh magus@<VPS_HOST> "jbh-web"   (port 22, key from VPS_SSH_KEY)
        ▼
VPS sshd: the key matches the line command="…/ci-deploy.sh",restrict
        │  sshd ignores the requested command and runs ci-deploy.sh.
        │  The sent text "jbh-web" goes into SSH_ORIGINAL_COMMAND.
        ▼
ci-deploy.sh: check the name → make deploy s=jbh-web
              (docker pull from ghcr.io, restart only jbh-web) → wait until healthy
        │  output and exit code go back over the same SSH connection
        ▼
GitHub run: green or red, with the full output in the log
```

The 3 secrets live in `jbh-deploy` (GitHub → Settings → Secrets and variables → Actions):

| Secret | What it is |
|--------|-----------|
| `VPS_HOST` | The VPS IP. |
| `VPS_SSH_KEY` | The private deploy key. Its public half is in `~/.ssh/authorized_keys` on the VPS. |
| `VPS_KNOWN_HOSTS` | The VPS host key, its "ID card". The runner refuses a server that shows another key, so it cannot connect to a fake server. |

Why the key is safe:

- `command="…/ci-deploy.sh"`: the key runs only this script, whatever the runner asks for.
- `restrict`: no shell, no terminal, no port forwarding.
- The script accepts only `jbh-web`, `jbh-gateway`, `jbh-iam` and `jbh-personal-finance`. Anything else ends with `Unknown service`.
- If the key leaks, it can only restart one of these 4 services with an image that is already in GHCR.

Two more facts:

- Only GitHub connects to the VPS. The VPS never calls GitHub, except `docker pull` from `ghcr.io` (as before).
- The runner IP changes on every run, so the VPS must accept SSH from the internet. It does: `ufw allow OpenSSH` (Magus setup).

#### Steps

The steps move between the laptop and the VPS. Keep your normal SSH session to the VPS open the whole time.

**1. VPS, `/home/magus/jbh-deploy`:** get `ci-deploy.sh`.

```bash
git pull
ls -l ci-deploy.sh               # must show -rwxr-xr-x
make config                      # must print: compose.yaml OK
```

If `make config` says `set JBH_JWT_SECRET in .env`, see §6.

**2. Laptop:** create the deploy key in an empty folder.

```bash
mkdir -p ~/jbh-ci-key && cd ~/jbh-ci-key
ssh-keygen -t ed25519 -N '' -C jbh-ci-deploy -f jbh-ci-deploy
cat jbh-ci-deploy.pub            # copy this line
```

**3. VPS, any folder:** allow the key, limited to the script.

```bash
cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak
echo 'command="/home/magus/jbh-deploy/ci-deploy.sh",restrict <paste the jbh-ci-deploy.pub line>' >> ~/.ssh/authorized_keys
tail -1 ~/.ssh/authorized_keys
```

Use `>>`, never `>`. A single `>` deletes your own key and locks you out.

**4. Laptop, `~/jbh-ci-key`:** test the key.

```bash
ssh -i jbh-ci-deploy -o IdentitiesOnly=yes magus@<vps-ip> hello
```

It must print `Unknown service: 'hello'` and close. If a shell opens, the `command=` part is wrong: fix step 3.
Without `IdentitiesOnly`, ssh may log in with your own key, and the test proves nothing.

**5. Laptop and VPS:** get the VPS host key, and check that it is the real one.

```bash
# Laptop, ~/jbh-ci-key
ssh-keyscan -t ed25519 <vps-ip> > known_hosts.txt
ssh-keygen -lf known_hosts.txt
# VPS, any folder
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Both must show the same `SHA256:...`.

**6. Laptop, `~/jbh-ci-key`:** save the 3 secrets, then delete the files.

```bash
gh secret set VPS_HOST -R kkpa-jbh/jbh-deploy -b '<vps-ip>'
gh secret set VPS_SSH_KEY -R kkpa-jbh/jbh-deploy < jbh-ci-deploy
gh secret set VPS_KNOWN_HOSTS -R kkpa-jbh/jbh-deploy < known_hosts.txt
cd ~ && rm -r ~/jbh-ci-key
```

The secret is now the only copy of the private key. If you lose it, make a new key (steps 2–6).

**7. Browser:** GitHub → `jbh-deploy` → Actions → `Deploy` → **Run workflow** → `jbh-web`.
It must end green with `jbh-web is running.`

**Block the key** (VPS, any folder): `sed -i '/jbh-ci-deploy$/d' ~/.ssh/authorized_keys`. Steps 2–6 make a new one.

## 2. Deploy an update

You never build on the VPS. The flow is always: **push → CI builds and publishes → the VPS pulls**.

### 2.1 What CI does on a push to `main`

Full details (steps, pull requests, secrets, image retention): [`CI.md`](CI.md).

| Repo | Workflow (GitHub → repo → Actions) | Publishes |
|------|-----------------------------------|-----------|
| `jbh-gateway` | `Image` | image `ghcr.io/kkpa-jbh/jbh-gateway` |
| `jbh-iam` | `Image` | image `ghcr.io/kkpa-jbh/jbh-iam` |
| `jbh-personal-finance` | `Image` | image `ghcr.io/kkpa-jbh/jbh-personal-finance` |
| `jbh-personal-finance` | `Publish notification contracts` (only when the contracts change) | Maven `jbh-notification-contracts` |
| `jbh-app` | `Image` | image `ghcr.io/kkpa-jbh/jbh-web` |
| `jbh-gateway-client` | `Publish` | Maven `jbh-gateway-client` |
| `jbh-deploy` | `Deploy` (by hand only) | nothing — deploys one service to the VPS (§2.2) |

Every image gets two tags: the full git SHA and `latest`. CI keeps only the 2 newest images per service, so a rollback reaches one deploy back.
Each workflow can also be started by hand: Actions → the workflow → **Run workflow**.

### 2.2 Deploy one service (the normal case)

1. **Laptop, the service repo:** commit and `git push origin main`.
2. **Browser or laptop:** wait until the `Image` workflow is green.
   GitHub → repo → Actions, or `gh run list -R kkpa-jbh/<repo> -w Image -L 1`. Takes 2–4 minutes.
3. **Browser:** GitHub → `jbh-deploy` → Actions → `Deploy` → **Run workflow**, pick the service
   (`jbh-gateway`, `jbh-iam`, `jbh-personal-finance` or `jbh-web`).
   It pulls the new image and restarts only that service. The others keep running.
   Green = the service is healthy (JVMs: 1–2 minutes). Red = it is not: the run log ends with the service's last 50 log lines.
4. **Or without the button, VPS, `/home/magus/jbh-deploy`:** `make deploy s=<service>`, then `make ps` until the
   service is `healthy`. If not: `make logs s=<service>` and read the **first** error.

`jbh-web` is the `jbh-app` repo: push `jbh-app`, deploy `s=jbh-web`.

### 2.3 A shared library changed (contracts or gateway-client)

The services include the library at build time, so the order matters:

1. **`jbh-personal-finance`** (only if `jbh-notification-contracts` changed): push → wait for
   `Publish notification contracts`.
2. **`jbh-gateway-client`**: push (or Run workflow) → wait for `Publish`.
3. **`jbh-iam`** and **`jbh-personal-finance`**: push, or **Run workflow** on `Image` when nothing else changed →
   wait for both.
4. **Deploy** `jbh-iam`, then `jbh-personal-finance` (the `Deploy` button, or `make deploy` on the VPS).

Skipping a step means an image is built with the old library.

### 2.4 Several services at once

Deploy them one by one, back end first: `jbh-iam` → `jbh-personal-finance` → `jbh-gateway` → `jbh-web`.
Wait until each one is healthy (a green `Deploy` run, or `make ps`) before the next.

### 2.5 A change in this repo (`jbh-deploy`)

1. **Laptop:** commit and push `jbh-deploy`.
2. **VPS, `/home/magus/jbh-deploy`:** `git pull`.
3. Then, by what changed:
   - `compose.yaml` or `.env` → `make up` (recreates only the services whose config changed).
   - `jbh.caddy` → `make caddy-install`.
   - A new variable in `.env.example` → add it to `.env` on the VPS first, then `make up`.
   - `ci-deploy.sh` → nothing more. The next `Deploy` run uses the new file.

### 2.6 Pin a version

With `JBH_<SERVICE>_TAG=latest` in `.env`, `make deploy` takes the newest image. To pin one version, put the full
40-character git SHA instead (`JBH_IAM_TAG=0a40993c82b3...`). Section 3 uses this for rollback.

## 3. Roll back

1. Find the old commit SHA: GitHub → the repo → Actions → a green `Image` run, or `git log` in the repo.
   Only the **last 2** images are kept (older ones are deleted to stay in the free 500 MB).
2. **VPS, `/home/magus/jbh-deploy`:** set `JBH_<SERVICE>_TAG=<full-sha>` in `.env`.
3. **VPS, `/home/magus/jbh-deploy`:** `make deploy s=<service>` (or the `Deploy` button: it reads the tag from `.env`).

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

### Connect from your laptop (IntelliJ, psql)

Postgres has no public port. You reach it through an SSH tunnel to the **container IP**.

1. **VPS, `/home/magus/jbh-deploy`:** `make db-tunnel`. It prints the container IP and the commands.
   The IP can change when the container is recreated (for example after `make up`). Run it again if a connection breaks.
2. **IntelliJ:** Database → **+** → Data Source → PostgreSQL.
   - **SSH/SSL** tab: **Use SSH tunnel**, host = the VPS IP, port `22`, your SSH user and key.
   - **General** tab: host = **the container IP** (not the VPS host, not `localhost`), port `5432`,
     user and password = `POSTGRES_USER` / `POSTGRES_PASSWORD` from `.env`, database `jbh` or `jbh_finance`.
3. **Or psql from the laptop:** run the printed `ssh -N -L 5433:<ip>:5432 ...`, then `psql -h localhost -p 5433 -U jbh_admin -d jbh`.

The General host is resolved **on the VPS**, at the end of the tunnel. With the VPS host or `localhost` there, you reach
`127.0.0.1:5432` on the VPS — that is **Magus's** database, not jbh's.

This is production and `jbh_admin` can change everything. Tick **Read-only** in the IntelliJ data source unless you must write.

## 6. When something is wrong

| Symptom | Where / what |
|---------|--------------|
| `502` on jbh.usemagus.cloud | VPS, `/home/magus/jbh-deploy`: `make ps`, then `make logs s=jbh-gateway` (or `jbh-web`). |
| `401` on every API call | `JBH_JWT_SECRET` differs between IAM and gateway? It is one value in `.env`; restart both with `make deploy`. |
| API returns `503` / "no instances" | The gateway cannot find a service in Consul. Check the Consul UI (tunnel above) and `make logs s=jbh-iam`. |
| `network edge ... could not be found` | VPS, `/home/magus/jbh-deploy`: `make network` (`make up` now runs it first). Then recreate Magus's Caddy (§1 step 7) so it joins `edge`. |
| `docker pull` → `denied` / `unauthorized` | The token expired. Create a new one, `docker login ghcr.io` again, and update `PACKAGES_READ_TOKEN` in the 3 repos. |
| CI: `Could not find artifact com.jbh:...` | `PACKAGES_READ_TOKEN` is missing or expired in that repo. |
| `make caddy-install`: `cp: ... Permission denied` | Docker created `/home/magus/caddy-sites` as `root` (it did not exist when Magus's Caddy started). VPS: `sudo chown magus:magus /home/magus/caddy-sites`, then retry. |
| `Deploy`: `Permission denied (publickey)` | The key line is missing in `~/.ssh/authorized_keys`, or `VPS_SSH_KEY` is wrong. Redo §1.1. |
| `Deploy`: `Host key verification failed` | `VPS_KNOWN_HOSTS` does not match the VPS (for example after a VPS rebuild). Redo §1.1 step 5, then only the `VPS_KNOWN_HOSTS` line of step 6. |
| `make config` or `Deploy`: `set JBH_JWT_SECRET in .env` | `.env` still has the old name `JWT_SECRET` (renamed on 2026-10-01). VPS, `/home/magus/jbh-deploy`: `cp .env ~/jbh-env-backup && chmod 600 ~/jbh-env-backup`, then `sed -i 's/^JWT_SECRET=/JBH_JWT_SECRET=/' .env`, then `make config`. Then deploy `jbh-iam` and `jbh-gateway`: their new images read the new name. |
| `Deploy`: `Unknown service` | `ci-deploy.sh` on the VPS is old. VPS, `/home/magus/jbh-deploy`: `git pull`. |
| Invitation emails do not arrive | `make logs s=jbh-personal-finance`; check `GMAIL_*` in `.env` (Gmail needs an app password). |

## 7. Limits and cost

- The VPS is already paid. DNS, the HTTPS certificate (Let's Encrypt) and Gmail SMTP are free.
- GitHub Free, private repos: 2,000 Actions minutes and **500 MB package storage + 1 GB download per month**.
  CI keeps only 2 images per service. With the default $0 spending limit, going over makes pushes or pulls fail;
  it does not create a bill. Check usage in GitHub → org settings → Billing.
