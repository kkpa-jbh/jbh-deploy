## ADDED Requirements

### Requirement: Faro logs carry service.name
`local.alloy` SHALL set the resource attribute `service.name` on Faro logs from the `app_name` field of the log line, before the logs reach `otelcol.exporter.otlp "lgtm"`,
using `otelcol.processor.transform` between `otelcol.receiver.loki "faro"` and the exporter. The Faro traces path SHALL NOT change.

#### Scenario: Faro log in Loki
- **WHEN** the browser app sends a Faro event with `app_name=jbh-web` and Alloy has restarted
- **THEN** Loki shows the line with `service_name="jbh-web"` and not `unknown_service`

#### Scenario: Line without app_name
- **WHEN** a Faro log line has no `app_name`
- **THEN** the line is still forwarded (`error_mode = "ignore"`) and Loki keeps `unknown_service` for it
