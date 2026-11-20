# Local dev stack

Start the whole JBH system with one command. Then stop the one container you change, and run that service from your IDE.
You test your code against the `main` version of the other services, before you open a PR.

`make local-up` pulls the `latest` images from GHCR. CI builds them from `main`. Only the service you swap runs your local code.
This is for your machine only. It never touches the VPS or the production `compose.yaml`.

## How it works

Every service saves the address `host.docker.internal` in Consul. Each container publishes its port on your Mac.
In a container, `host.docker.internal` points to the Mac. On the Mac, one line in `/etc/hosts` does the same.
So the gateway reaches a service at the same address when it runs in Docker or in your IDE. A swap changes nothing in Consul.

| Service | Mac port |
|---------|----------|
| `jbh-gateway` | 8080 |
| `jbh-iam` | 9999 |
| `jbh-personal-finance` | 7777 |
| `jbh-notification` | 7778 |
| Consul (UI) | 8500 |
| Postgres | 5433 |
| Alloy, OTLP gRPC (for a service in the IDE) | 14317 |
| Alloy, OTLP HTTP | 14318 |
| Alloy, Faro receiver (browser) | 12347 |
| Alloy, UI | 12345 |

The four Alloy ports are published on `127.0.0.1` only. `14317` and `14318` are not `4317` and `4318`, because the local LGTM already uses those.

Postgres is a container with its own empty data. It is not the Postgres on your Mac (5432).

### How a container gets its config

An image holds no config: only the jar and Java. The values come in when the container starts:

1. `.env.local` holds your values (passwords, `JBH_JWT_SECRET`, API keys, the optional `*_XMX` and `*_MEM_LIMIT`).
2. `compose.local.yaml` lists the env vars of each service, with placeholders: `JBH_JWT_SECRET: ${JBH_JWT_SECRET}`,
   `JAVA_OPTS: -Xmx${IAM_XMX:-384m}` (the value after `:-` is the default).
3. `make local-up` runs `docker compose --env-file .env.local ...`. Compose fills every `${...}`. `make` removes your shell exports of the same keys first.
4. Docker starts the container with the result as normal env vars. Spring Boot (`application.yml`) and Quarkus (`application.properties`) read them.

The VPS runs the **same image** with `compose.yaml` and its own `.env`. Build once, configure per environment.

- After a change to `.env.local` or `compose.local.yaml`, run `make local-up`. It recreates only the containers whose config changed.
  `docker restart` keeps the old values.
- To see what a container got: `docker inspect jbh-local-jbh-iam-1 --format '{{json .Config.Env}}'`. **It prints the secrets in clear text.**

## One-time setup

1. Add this line to `/etc/hosts`: `127.0.0.1 host.docker.internal`
2. Log in to GHCR if the packages are not public: `docker login ghcr.io` (token with `read:packages`).
3. `cp .env.local.example .env.local`, then fill it. Set `POSTGRES_PASSWORD` and `JBH_JWT_SECRET` (`openssl rand -base64 32`).
   Mail and AI keys can stay empty.
   `make local-*` ignores shell exports of the keys in `.env.local.example` (for example `POSTGRES_USER` from `~/.zshrc`).
   `.env.local` is the only source: change values there.
4. Stop the standalone Consul (it also uses port 8500): run `make consul down` in `kkpa-docker-lab`.

## Daily use

1. `make local-up`
2. Open http://localhost:8500. `jbh-iam-service`, `jbh-personal-finance`, `jbh-notification` and `API Gateway` must be healthy.
   Each one must show the address `host.docker.internal`.
3. In `jbh-app`: `ionic serve`, then sign in.
4. `make local-ps` shows the containers. `make local-logs s=<service>` follows one log. `make local-down` stops all.

The first start creates the databases. The services run their Liquibase migrations at start.

## Observability (Alloy and the local LGTM)

`jbh-alloy` (Grafana Alloy) collects traces, logs and metrics and sends them to the local LGTM from `kkpa-docker-lab`.
Design and tools: [`observability/README.md`](observability/README.md).

1. Start the local LGTM first. In `kkpa-docker-lab`: `make lgtm up`.
2. Start Alloy: `make local-up` (it starts with the rest), or `make local-alloy` (only Alloy, for work in the IDE; Postgres must run).
3. `make local-alloy-logs` follows the Alloy log. The Alloy UI is http://localhost:12345: every component must be healthy.
4. See the data in Grafana: http://localhost:3000, then **Explore**. Pick Tempo (traces), Loki (logs) or Prometheus (metrics).

### A service run from the IDE (c)

A service in the IDE sends OTLP to Alloy on the Mac port `14317`, and export is off by default.
`make local-swap s=<service>` prints `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14317`, `OTEL_SDK_DISABLED=false` and `JBH_ENV=local`.

Put the printed values in the IDE run configuration, or in the service's local profile. Alloy scrapes the metrics endpoints at `host.docker.internal`,
so a service in the IDE needs no change for metrics.

### Existing Postgres volume (a)

`initdb/` runs only on an empty volume. If your `jbh-local-pgdata` volume already exists, create the monitor role once.
Set `JBH_PG_MONITOR_PASSWORD` in `.env.local` (a URL-safe value), then run:

```
PG_ADMIN_URL=postgresql://jbh_admin@localhost:5433/postgres make local-pg-monitor
```

Use your `POSTGRES_USER` instead of `jbh_admin` if you changed it. If psql asks for the admin password, set `PGPASSWORD` or use `~/.pgpass`:
no password is read from a file by the script. The container already loads `pg_stat_statements` in its command, so no restart is needed.
Then run `make local-up`: compose recreates `jbh-postgres` if its command changed. Until the role exists, Alloy logs an authentication error for Postgres. Other signals work.

### Postgres installed on the Mac (b)

If you scrape the Postgres on your Mac (port 5432) and not the container:

1. Run `make local-pg-monitor` (it uses `postgresql://localhost:5432/postgres` and your current user, which must be a superuser).
2. If `shared_preload_libraries` is empty, the script sets it to `pg_stat_statements` with `ALTER SYSTEM`, prints the restart command and stops without creating the role.
   If it holds other libraries, the script prints them, changes nothing and exits 1: add `pg_stat_statements` by hand.
3. Restart that Postgres (Homebrew: `brew services restart postgresql@16`). The script never restarts it.
4. Run `make local-pg-monitor` again. It prints `jbh_monitor is ready`. You can run it as many times as you want.
5. In `.env.local` set the override, so Alloy reaches the Mac and not the container:

   ```
   JBH_PG_MONITOR_DSN=postgresql://jbh_monitor:<password>@host.docker.internal:5432/postgres?sslmode=disable
   ```

Then `make local-alloy` to restart Alloy with the new value.

What the script runs: [`initdb/sql/pg-monitor.sql`](initdb/sql/pg-monitor.sql). A new Docker volume runs the same file from `initdb/02-create-monitor-role.sh`.

## Swap one service for your IDE

1. `make local-swap s=jbh-iam` (also `jbh-personal-finance`, `jbh-notification` or `jbh-gateway`). It stops that container
   and prints the env vars for the IDE, read from `compose.local.yaml`. Secrets show as `<from .env.local>`: copy them from `.env.local`.
   To load the real values from one file instead, see [Env file for the IDE](#env-file-for-the-ide-jbhenv).
2. Run the same service from your IDE with those env vars.
3. When you finish: stop it in the IDE, then `make local-restore s=jbh-iam`.

The printed ports differ from the container ones, because the Mac Postgres and the local LGTM own the defaults:
Postgres is `localhost:5433` (container 5432) and OTLP is `localhost:14317` (container 4317).
`JBH_JWT_SECRET` must be the same value in `jbh-iam` and `jbh-gateway`. If it differs, every call gets a 401.

## Env file for the IDE (jbh.env)

`make local-ide-env` writes `jbh.env` in this folder. It holds the env vars of `jbh-iam`, `jbh-personal-finance`, `jbh-notification`
and `jbh-gateway` in one list of `KEY=value` lines, read from `compose.local.yaml`. A key with the same value in several services appears once.
If one key has different values in two services, the command stops, writes nothing and names the key and the services.

**`jbh.env` holds real secrets** (your `.env.local` values; `make` removes your shell exports of those keys first). It has mode 600 and is git-ignored. Never commit it or share it.

`SPRING_PROFILES_ACTIVE` is not in the file: it would start the `local` profile in `jbh-gateway` too. Set the profile in each run configuration
(`jbh-iam`: `local`).

IntelliJ steps (EnvFile plugin):

1. Install the EnvFile plugin. Newer IntelliJ versions may load an env file without it.
2. Run, Edit Configurations, pick the service, tab **EnvFile**.
3. Tick **Enable EnvFile**, click `+`, choose **.env file**, then pick `<path>/jbh-deploy/jbh.env`.
4. Set the profile in the run configuration, then run the service.

After `compose.local.yaml` or `.env.local` changes, run `make local-ide-env` again and restart the service.
`make local-swap s=<service>` still prints the masked values of one service.

Quarkus (`jbh-personal-finance`, `jbh-notification`) reads a `.env` file in its working directory. Link the same file, from `jbh-deploy`:

```
ln -s "$PWD/jbh.env" ../jbh-personal-finance/.env
ln -s "$PWD/jbh.env" ../jbh-notification/.env
```

Before you link, run `git check-ignore .env` in that repo. It must print `.env`. If it prints nothing, add `.env` to that repo's `.gitignore` first:
the link shows real secrets in that repo. If the run configuration has another working directory, link the `.env` there. There is no make target for this.

## Catches

- If you forget `local-swap`, the service in your IDE cannot start: the port is taken. Two copies never run at once.
- IAM runs with the `local` profile in Docker. The `prod` profile sets Secure cookies, and a browser drops them on `http://localhost`.
  The `local` profile also writes `jbh-iam.log` to `/logs`. Compose mounts `kkpa-jbh/logs` there, so the file lands in the same folder
  as an IDE run (`kkpa-jbh/logs/jbh-iam.log`, old days in `archived/`). Without the mount, IAM stops with "Logback configuration error detected".
  Only IAM writes a log file. The other services log to the console: `make local-logs s=<service>`.
- The finance image must include the `CONSUL_DISCOVERY_HOSTNAME` change (JBH-63). An older `latest` image saves its container ID in Consul, and the gateway returns 503.
- `make local-up` does not start `jbh-web`. `ionic serve` stays the frontend.
- The local LGTM does not scrape the JBH services: its old `jbh-personal-finance` and `jbh-iam` jobs were removed from
  `kkpa-docker-lab/lgtm/prometheus.yaml`. Do not add scrape jobs there. Alloy already sends these series, so they would be stored twice.
- Postgres sets its user and password only at the first start of an empty volume. The `jbh-local-pgdata` volume keeps the first user.
  If `POSTGRES_USER` or `POSTGRES_PASSWORD` in `.env.local` differ from it, IAM and finance cannot log in. Two fixes:
  set `.env.local` to the values of the volume, or recreate the volume. **The second fix deletes all local database data:**
  `make local-down`, then `docker volume rm jbh-local_jbh-local-pgdata`, then `make local-up`.
- Images are `latest`: a new `main` build changes what you test. `make local-up` pulls them each time.
- Each container has the production memory limit, and each JVM the production heap cap (`-Xmx`), about 3.4 GB for the whole stack.
  A container that needs more is killed (`make local-ps` shows exit code 137). Raise its `*_MEM_LIMIT` and `*_XMX` in `.env.local`
  (the keys are in `.env.local.example`), then `make local-up`. A swapped service in the IDE has no limit.
