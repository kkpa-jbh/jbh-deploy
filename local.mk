# Local dev stack (see LOCAL.md). Included by the Makefile.
# These commands are for your machine. The VPS commands stay in the Makefile.

LOCAL_COMPOSE = docker compose --env-file .env.local -f compose.local.yaml
# Services you can swap for a copy that runs in your IDE.
LOCAL_SWAPPABLE = jbh-iam jbh-personal-finance jbh-notification jbh-gateway

.PHONY: local-up local-down local-ps local-logs local-swap local-ide-env local-restore local-alloy local-alloy-logs local-pg-monitor

# Port 8500 is also used by kkpa-docker-lab/consul. Compose fails with "port is already allocated" if it still runs.
local-up:
	@test -f .env.local || (echo "Missing .env.local. Run: cp .env.local.example .env.local" && exit 1)
	$(LOCAL_COMPOSE) up -d

local-down:
	$(LOCAL_COMPOSE) down

local-ps:
	$(LOCAL_COMPOSE) ps

local-logs:
	$(LOCAL_COMPOSE) logs -f --tail=200 $(s)

# Stops the container and prints the IDE env vars (from local-swap-env.sh, secrets masked). Its port is free, so the same service can start in your IDE.
# The script runs before the stop: a missing tool or file ends the target while the container still runs.
local-swap:
	@test -n "$(s)" || (echo "usage: make local-swap s=<service>   ($(LOCAL_SWAPPABLE))" && exit 1)
	@echo "$(LOCAL_SWAPPABLE)" | tr ' ' '\n' | grep -qx "$(s)" || (echo "$(s) cannot be swapped. Use: $(LOCAL_SWAPPABLE)" && exit 1)
	@vars="$$(sh ./local-swap-env.sh $(s))" || exit 1; \
	$(LOCAL_COMPOSE) stop $(s) || exit 1; \
	echo ""; \
	echo "$(s) is stopped. Start it from your IDE with these env vars:"; \
	printf '%s\n' "$$vars" | sed 's/^/  /'; \
	echo "Consul is at localhost:8500. Undo with: make local-restore s=$(s)"

# Writes jbh.env: the env vars of all four swappable services in one file, with REAL secrets (mode 600, git-ignored).
# Run it again after compose.local.yaml or .env.local changes. Steps: LOCAL.md.
local-ide-env:
	@sh ./local-swap-env.sh --write-all jbh.env

local-restore:
	@test -n "$(s)" || (echo "usage: make local-restore s=<service>   ($(LOCAL_SWAPPABLE))" && exit 1)
	@echo "$(LOCAL_SWAPPABLE)" | tr ' ' '\n' | grep -qx "$(s)" || (echo "$(s) cannot be swapped. Use: $(LOCAL_SWAPPABLE)" && exit 1)
	$(LOCAL_COMPOSE) up -d $(s)

# Only Alloy, for work in the IDE (Postgres must run: make local-up, or Postgres on your Mac: make local-pg-monitor first). Start the local LGTM first.
# A service in the IDE sends OTLP to http://localhost:14317.
local-alloy:
	@test -f .env.local || (echo "Missing .env.local. Run: cp .env.local.example .env.local" && exit 1)
	$(LOCAL_COMPOSE) up -d jbh-alloy

local-alloy-logs:
	$(LOCAL_COMPOSE) logs -f --tail=200 jbh-alloy

# Prepares an existing Postgres for Alloy (LOCAL.md). Reads only JBH_PG_MONITOR_PASSWORD from .env.local:
# the file is not sourced (other lines may hold spaces), and "@" keeps make from printing the value.
# Docker volume: PG_ADMIN_URL=postgresql://jbh_admin@localhost:5433/postgres make local-pg-monitor
local-pg-monitor:
	@test -f .env.local || (echo "Missing .env.local. Run: cp .env.local.example .env.local" && exit 1)
	@JBH_PG_MONITOR_PASSWORD="$$(sed -n 's/^JBH_PG_MONITOR_PASSWORD=//p' .env.local | tail -n 1)" sh ./local-pg-monitor.sh
