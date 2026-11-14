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
| Consul (UI) | 8500 |
| Postgres | 5433 |

Postgres is a container with its own empty data. It is not the Postgres on your Mac (5432).

## One-time setup

1. Add this line to `/etc/hosts`: `127.0.0.1 host.docker.internal`
2. Log in to GHCR if the packages are not public: `docker login ghcr.io` (token with `read:packages`).
3. `cp .env.local.example .env.local`, then fill it. Set `POSTGRES_PASSWORD` and `JBH_JWT_SECRET` (`openssl rand -base64 32`).
   Mail and AI keys can stay empty.
4. Stop the standalone Consul (it also uses port 8500): run `make consul down` in `kkpa-docker-lab`.

## Daily use

1. `make local-up`
2. Open http://localhost:8500. `jbh-iam-service`, `jbh-personal-finance` and `API Gateway` must be healthy.
   Each one must show the address `host.docker.internal`.
3. In `jbh-app`: `ionic serve`, then sign in.
4. `make local-ps` shows the containers. `make local-logs s=<service>` follows one log. `make local-down` stops all.

The first start creates the databases. The services run their Liquibase migrations at start.

## Swap one service for your IDE

1. `make local-swap s=jbh-iam` (also `jbh-personal-finance` or `jbh-gateway`). It stops that container and prints the env vars.
2. Run the same service from your IDE with those env vars.
3. When you finish: stop it in the IDE, then `make local-restore s=jbh-iam`.

Env vars for a service you run from the IDE:

| Service | Env vars |
|---------|----------|
| all three | `CONSUL_DISCOVERY_HOSTNAME=host.docker.internal` |
| `jbh-iam`, `jbh-gateway` | `JBH_JWT_SECRET` = the same value as in `.env.local`. If it differs, every call gets a 401. |
| `jbh-iam` | Profile `local`. Database: `DB_HOST=localhost`, `DB_PORT=5433`, `DB_NAME=jbh`, `DB_USERNAME`, `JBH_ADMIN_PASS` (the Postgres values from `.env.local`). |
| `jbh-personal-finance` | `DATABASE_URL=jdbc:postgresql://localhost:5433/jbh_finance`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`. Quarkus dev mode already sets `CONSUL_HEALTH_CHECK_HOST=host.docker.internal`. |

## Catches

- If you forget `local-swap`, the service in your IDE cannot start: the port is taken. Two copies never run at once.
- IAM runs with the `local` profile in Docker. The `prod` profile sets Secure cookies, and a browser drops them on `http://localhost`.
- The finance image must include the `CONSUL_DISCOVERY_HOSTNAME` change (JBH-63). An older `latest` image saves its container ID in Consul, and the gateway returns 503.
- `make local-up` does not start `jbh-web`. `ionic serve` stays the frontend.
- Images are `latest`: a new `main` build changes what you test. `make local-up` pulls them each time.
