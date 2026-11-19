## MODIFIED Requirements

### Requirement: Local compose runs jbh-notification
`compose.local.yaml` SHALL define `jbh-notification` with image `ghcr.io/kkpa-jbh/jbh-notification:latest`, host port `7778:7778`,
`CONSUL_DISCOVERY_HOSTNAME` `host.docker.internal`, the same database as finance, and empty-default `GMAIL_*` values.

#### Scenario: Local file is valid
- **WHEN** `docker compose --env-file .env.local.example -f compose.local.yaml config -q` runs
- **THEN** it exits 0 and the rendered `jbh-notification` publishes port 7778

#### Scenario: Swap for the IDE
- **WHEN** a developer runs `make local-swap s=jbh-notification`
- **THEN** the container stops and the target prints, among others, `DATABASE_URL=jdbc:postgresql://localhost:5433/jbh_finance`, `DATABASE_USERNAME` and `DATABASE_PASSWORD=<from .env.local>`
