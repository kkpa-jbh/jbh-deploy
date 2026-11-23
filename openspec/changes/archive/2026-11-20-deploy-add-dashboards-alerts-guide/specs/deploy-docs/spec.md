## ADDED Requirements

### Requirement: Final doc check for dashboards, alerts and the guide
`README.md` SHALL have, in "### 1. Frontend to gateway", the bullet: every gateway response carries `X-Trace-Id` (the W3C trace id), also 401, 404, 429 and 5xx, searched in Grafana, Explore, Tempo.
`README.md` SHALL say in its "Observability (local)" section that the browser (`jbh-app`, Faro) sends to the Alloy `faro.receiver` on port `12347`, and SHALL NOT change the "Production" section.
`observability/README.md` SHALL list the 5 dashboards and 7 alerts, explain the manual UI import of dashboards and the manual creation of alert rules, show the gateway estimate (about 700 typical, about 1,400 worst case, target 1,500 or less)
with the real-count command, and have a "Hand-over to JBH-84" section with: the env var `JBH_SERVICE_VERSION` (resource attribute `service.version`, default `unknown`), the CSP note, and the data source uids used by the alert files.
`LOCAL.md` SHALL point to `observability/GUIDE.md` and to the dashboards. `CLAUDE.md` SHALL list `observability/grafana/`, `observability/alerts/` and `observability/GUIDE.md` in its files table.
`compose.yaml`, `compose.local.yaml`, `.env.example`, `DEPLOY.md`, `Makefile`, `ci-deploy.sh` and `.github/` SHALL NOT change.

#### Scenario: CSP hand-over
- **WHEN** the JBH-84 owner reads "Hand-over to JBH-84" in `observability/README.md`
- **THEN** it says that no CSP exists today (`jbh-app/src/index.html`, `jbh-app` `deploy/Caddyfile`, `jbh.caddy`) and that a new CSP must allow the Faro collector host in `connect-src`

#### Scenario: Version hand-over
- **WHEN** the same reader looks for `JBH_SERVICE_VERSION`
- **THEN** the section says it is a new env var for the services in `compose.yaml`, default `unknown`
