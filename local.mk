# Local dev stack (see LOCAL.md). Included by the Makefile.
# These commands are for your machine. The VPS commands stay in the Makefile.

LOCAL_COMPOSE = docker compose --env-file .env.local -f compose.local.yaml
# Services you can swap for a copy that runs in your IDE.
LOCAL_SWAPPABLE = jbh-iam jbh-personal-finance jbh-notification jbh-gateway

.PHONY: local-up local-down local-ps local-logs local-swap local-restore local-alloy local-alloy-logs

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

# Stops the container. Its port is free, so the same service can start in your IDE.
local-swap:
	@test -n "$(s)" || (echo "usage: make local-swap s=<service>   ($(LOCAL_SWAPPABLE))" && exit 1)
	@echo "$(LOCAL_SWAPPABLE)" | tr ' ' '\n' | grep -qx "$(s)" || (echo "$(s) cannot be swapped. Use: $(LOCAL_SWAPPABLE)" && exit 1)
	$(LOCAL_COMPOSE) stop $(s)
	@echo ""
	@echo "$(s) is stopped. Start it from your IDE with these env vars:"
	@echo "  CONSUL_DISCOVERY_HOSTNAME=host.docker.internal"
	@case "$(s)" in \
	  jbh-iam) echo "  JBH_JWT_SECRET=<same value as in .env.local>"; \
	           echo "  DB_HOST=localhost DB_PORT=5433 DB_NAME=jbh DB_USERNAME=<POSTGRES_USER> JBH_ADMIN_PASS=<POSTGRES_PASSWORD>"; \
	           echo "  Profile: local" ;; \
	  jbh-gateway) echo "  JBH_JWT_SECRET=<same value as in .env.local>" ;; \
	  jbh-personal-finance) echo "  DATABASE_URL=jdbc:postgresql://localhost:5433/jbh_finance DATABASE_USERNAME=<POSTGRES_USER> DATABASE_PASSWORD=<POSTGRES_PASSWORD>"; \
	           echo "  CONSUL_HEALTH_CHECK_HOST already defaults to host.docker.internal in Quarkus dev mode" ;; \
		  jbh-notification) echo "  DATABASE_URL=jdbc:postgresql://localhost:5433/jbh_finance DATABASE_USERNAME=<POSTGRES_USER> DATABASE_PASSWORD=<POSTGRES_PASSWORD>"; \
		           echo "  Optional: the GMAIL_* variables, and JBH_FRONTEND_URL=http://localhost:8100" ;; \
	esac
	@echo "Consul is at localhost:8500 (the default CONSUL_HOST). Undo with: make local-restore s=$(s)"

local-restore:
	@test -n "$(s)" || (echo "usage: make local-restore s=<service>   ($(LOCAL_SWAPPABLE))" && exit 1)
	@echo "$(LOCAL_SWAPPABLE)" | tr ' ' '\n' | grep -qx "$(s)" || (echo "$(s) cannot be swapped. Use: $(LOCAL_SWAPPABLE)" && exit 1)
	$(LOCAL_COMPOSE) up -d $(s)

# Only Alloy, for work in the IDE (Postgres must run: make local-up). Start the local LGTM first.
# A service in the IDE sends OTLP to http://localhost:14317.
local-alloy:
	@test -f .env.local || (echo "Missing .env.local. Run: cp .env.local.example .env.local" && exit 1)
	$(LOCAL_COMPOSE) up -d jbh-alloy

local-alloy-logs:
	$(LOCAL_COMPOSE) logs -f --tail=200 jbh-alloy
