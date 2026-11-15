# deploy-docs Specification

## Purpose
TBD - created by archiving change deploy-add-notification-service. Update Purpose after archive.
## Requirements
### Requirement: System map shows the new service
`README.md` SHALL list `jbh-notification` (port 7778, Consul name `jbh-notification`) and `jbh-commons-lib` in the projects table,
route `/jbh-api/notifications/**` to `jbh-notification` in the mermaid graph, the route table and the endpoint prefix table,
and `jbh-iam` → `jbh-notification` in the service-to-service table. It SHALL show `jbh-notification` in the databases, start order, env table and memory note.
It SHALL NOT list notifications under `jbh-personal-finance`, and SHALL NOT contain the "Build cycle" known gap.

#### Scenario: Route table is current
- **WHEN** a reader looks up `/jbh-api/notifications/**` in `README.md`
- **THEN** the target is `jbh-notification`, and the text says Caddy still answers `404` from the internet

#### Scenario: Build order has no cycle
- **WHEN** a reader looks at "Build dependencies between projects"
- **THEN** the order is `jbh-commons-lib` → `jbh-notification-contracts` (from `jbh-notification`) → `jbh-gateway-client` → services

### Requirement: CI.md matches the real workflows
`CI.md` SHALL NOT mention `publish-contracts` for `jbh-personal-finance`. It SHALL describe from the real workflow files:
`jbh-commons-lib` `CI` (`ci.yml`, `mvn -B verify` on pull requests into `main`) and `Publish` (`publish.yml`, on push to `main`);
`jbh-notification` `Image` (`image.yml`, image `ghcr.io/kkpa-jbh/jbh-notification`) and `Publish notification contracts` (`publish.yml`).
It SHALL list `jbh-notification` among the repos that need `PACKAGES_READ_TOKEN`, and give the publish order commons → contracts → client → services.

#### Scenario: Publish order is documented
- **WHEN** a reader looks at "Order for shared libraries"
- **THEN** the steps are `jbh-commons-lib` `Publish`, `jbh-notification` `Publish notification contracts`, `jbh-gateway-client` `Publish`, then the `Image` workflows

### Requirement: Local and deploy docs cover the new service
`LOCAL.md` SHALL list `jbh-notification` (port 7778) and `make local-swap s=jbh-notification`. `DEPLOY.md` SHALL list 5 app services and the
`jbh-notification` workflows, and SHALL hold the release order: deploy `jbh-notification` first and wait until it is healthy in Consul
(the gateway route answers `503` before that); then `jbh-gateway` and `jbh-personal-finance` in any order, because the gateway routes to one
service at a time and no email is sent twice; until finance is deployed without its notification module, do not change the `notifications` Liquibase changelog.
`aws/README.md` and `observability/README.md` SHALL match the code.

#### Scenario: Operator follows the release order
- **WHEN** an operator reads `DEPLOY.md` before the JBH-74 release
- **THEN** the first step is to set `JBH_NOTIFICATION_TAG` in `.env` and deploy `jbh-notification`, with the `503` and Liquibase warnings next to it

