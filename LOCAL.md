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

## One-time setup

1. Add this line to `/etc/hosts`: `127.0.0.1 host.docker.internal`
2. Log in to GHCR if the packages are not public: `docker login ghcr.io` (token with `read:packages`).
3. `cp .env.local.example .env.local`, then fill it. Set `POSTGRES_PASSWORD` and `JBH_JWT_SECRET` (`openssl rand -base64 32`).
   Mail and AI keys can stay empty.
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
2. Run the same service from your IDE with those env vars.
3. When you finish: stop it in the IDE, then `make local-restore s=jbh-iam`.

The printed ports differ from the container ones, because the Mac Postgres and the local LGTM own the defaults:
Postgres is `localhost:5433` (container 5432) and OTLP is `localhost:14317` (container 4317).
`JBH_JWT_SECRET` must be the same value in `jbh-iam` and `jbh-gateway`. If it differs, every call gets a 401.

## Catches

- If you forget `local-swap`, the service in your IDE cannot start: the port is taken. Two copies never run at once.
- IAM runs with the `local` profile in Docker. The `prod` profile sets Secure cookies, and a browser drops them on `http://localhost`.
- The finance image must include the `CONSUL_DISCOVERY_HOSTNAME` change (JBH-63). An older `latest` image saves its container ID in Consul, and the gateway returns 503.
- `make local-up` does not start `jbh-web`. `ionic serve` stays the frontend.
- The local LGTM does not scrape the JBH services: its old `jbh-personal-finance` and `jbh-iam` jobs were removed from
  `kkpa-docker-lab/lgtm/prometheus.yaml`. Do not add scrape jobs there. Alloy already sends these series, so they would be stored twice.
- Images are `latest`: a new `main` build changes what you test. `make local-up` pulls them each time.
