## ADDED Requirements

### Requirement: Docs describe Alloy and the observability setup
`README.md` SHALL show `jbh-alloy` in the "Production" picture and env var table, the OTLP variables of the four backends, the Postgres monitor role, the memory total of about 3.5 GB, and the dev OTLP port `14317`.
`LOCAL.md` SHALL explain how to start the local LGTM and then Alloy (`make local-up` or `make local-alloy`), list the published Alloy ports, and give `http://localhost:14317` as the OTLP endpoint for a service run from the IDE.
`DEPLOY.md` SHALL explain the Grafana Cloud stack and the access policy token (scopes: metrics write, logs write, traces write), where each value goes in `.env`, the one-time Postgres steps, and how to check that data arrives.
`observability/README.md` SHALL hold the series budget table and say that Alloy scrapes the metrics both locally and in production.
`CLAUDE.md` SHALL list `observability/alloy/` and the new `initdb/` script in its files table.

#### Scenario: Reader finds the OTLP endpoint for the IDE
- **WHEN** a reader looks in `LOCAL.md` for the endpoint of a service run from the IDE
- **THEN** it says `http://localhost:14317`

#### Scenario: Reader finds the series budget
- **WHEN** a reader opens `observability/README.md`
- **THEN** a table lists each source with its estimated series and a total of at most 6,000
