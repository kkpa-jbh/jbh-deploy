## ADDED Requirements

### Requirement: Docs describe the local Alloy setup
`README.md` SHALL have a short local "Observability" paragraph, name the dev OTLP port `14317`, and link to `observability/README.md`. It SHALL NOT change the "Production" section.
`LOCAL.md` SHALL explain how to start the local LGTM and then Alloy (`make local-up` or `make local-alloy`), list the published Alloy ports, give `http://localhost:14317` as the OTLP endpoint for a service run from the IDE, give the monitor SQL for an existing local volume, the `postgresql.conf` lines and SQL for a Postgres installed on the Mac (port 5432), and say that an IDE service needs `OTEL_SDK_DISABLED=false`.
`observability/README.md` SHALL hold the series budget table for the local scope and say that Alloy scrapes the metrics locally.
`CLAUDE.md` SHALL list `observability/alloy/` and the new `initdb/` script in its files table.

#### Scenario: Reader finds the OTLP endpoint for the IDE
- **WHEN** a reader looks in `LOCAL.md` for the endpoint of a service run from the IDE
- **THEN** it says `http://localhost:14317`

#### Scenario: Reader finds the series budget
- **WHEN** a reader opens `observability/README.md`
- **THEN** a table lists each local source with its estimated series and a total, and says the prod budget belongs to JBH-84
