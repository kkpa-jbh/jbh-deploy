## Why

JBH-55 gives the JBH services traces, logs and metrics in the local LGTM (sections 1-7 are merged, so real metric names exist).
Today only one dashboard exists (circuit breakers), there are no alert rules, and the user is new to Grafana.
This change is section 8 of the plan (sub-issue JBH-61, parent JBH-55): dashboards and alerts as code, a beginner guide, and the final doc check.
Three extra items come from the system leader: Faro logs show `service_name="unknown_service"` in Loki, the system map lacks the Faro line,
and JBH-84 needs a note about CSP.

## What Changes

- 4 new dashboards in `observability/grafana/`: `jbh-overview.json`, `jbh-service.json`, `jbh-postgres.json`, `jbh-traces.json`. `jbh-circuit-breakers.json` stays unchanged.
  Each has a fixed `uid` and a data source variable.
- 7 alert rules in `observability/alerts/` (one YAML file each, Grafana alert rule provisioning format), each with a "what to check first" annotation.
- `observability/GUIDE.md`: beginner guide with the 7 parts of the plan.
- `observability/README.md`: lists the dashboards and alerts, explains the manual import in the UI, new "Hand-over to JBH-84" section, gateway series budget.
- `observability/alloy/local.alloy`: a processor sets `service.name` on Faro logs from `app_name` (value `jbh-web`), so Loki shows `service_name="jbh-web"`.
- `README.md` (system map): the `X-Trace-Id` bullet, one line for the Faro receiver on port 12347.
  `LOCAL.md`: pointers to the guide and the dashboards. `CLAUDE.md`: files table row.
- `observability/VERIFY.md`: a hands-on checklist (5 scenarios) to verify observability on the local stack. Linked from `GUIDE.md` and `observability/README.md`.
- Outside the repo (not git, written by the leader): `/Users/cristianpena/cpena/sw/github/kkpa-jbh/kkpa/observability.md`, a 5-10 line pointer.

## Capabilities

### New Capabilities

- `grafana-dashboards`: the 4 new dashboard JSON files and the rules every dashboard follows.
- `grafana-alerts`: the 7 alert rule files and their format.
- `observability-guide`: `observability/GUIDE.md` (7 parts), `observability/VERIFY.md` (5 scenarios) and the pointer file.

### Modified Capabilities

- `alloy-deploy`: adds the requirement that Faro logs get `service.name` from `app_name`.
- `deploy-docs`: adds the requirement for the final doc check (`README.md`, `LOCAL.md`, `observability/README.md`, `CLAUDE.md`).
  (Both are added as new requirements. No existing requirement text changes.)

## Impact

- Files: 4 dashboards, 7 alert files, `GUIDE.md`, `VERIFY.md`, `observability/README.md`, `local.alloy`, `README.md`, `LOCAL.md`, `CLAUDE.md`, and the pointer file outside the repo.
- Local only. Production is not touched.
- After the `local.alloy` change the user restarts Alloy (`make local-alloy`). Old Faro log lines in Loki keep `unknown_service` until they expire.

## Non-goals

- No unit tests and no integration tests (plan: "Unit tests: excluded"). The change holds only JSON, YAML, Alloy config and Markdown. No test blueprint.
- No import script, make target or Grafana API call. Import is by hand in the UI.
- No change to `compose.yaml`, `compose.local.yaml`, `.env.example`, `DEPLOY.md`, `Makefile`, `ci-deploy.sh`, `.github/`, `jbh.caddy`, or `../kkpa-docker-lab`.
- Not here, JBH-84: email contact point, VPS host alert rules (disk, memory), Grafana Cloud quota rule, alert tests, alert provisioning in Grafana Cloud, a CSP, prod Faro.
- `VERIFY.md` never asks the assistant to stop or start a container: the user does those steps.
- No own frontend dashboard (the overview links to Grafana Cloud Frontend Observability).
