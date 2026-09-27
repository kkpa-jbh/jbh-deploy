# JBH deploy commands. Run on the VPS from this folder, with .env filled in.
# Start order on a new VPS: make network (once) → make up → make caddy-install.

# Only MAGUS_CADDY_CONTAINER and CADDY_SITES_DIR are read here. Compose reads .env itself.
-include .env

COMPOSE = docker compose --env-file .env -f compose.yaml
SUBNET  = 10.231.0.0/24

.PHONY: help network pull up down ps logs deploy caddy-install consul-tunnel backup config

help:
	@echo "make network           Create the shared 'edge' network (once, before Magus's next up)"
	@echo "make pull | up | down  Pull images / start all / stop all"
	@echo "make ps | logs s=<svc> Status / follow one service's logs"
	@echo "make deploy s=<svc>    Pull and restart one service (rollback: old tag in .env first)"
	@echo "make caddy-install     Copy jbh.caddy into Magus's sites folder, validate, reload"
	@echo "make consul-tunnel     Print the SSH command for the Consul UI"
	@echo "make backup            Dump both databases into backups/"
	@echo "make config            Check compose.yaml with the current .env"

network:
	docker network inspect edge >/dev/null 2>&1 || docker network create --subnet $(SUBNET) edge

pull:
	$(COMPOSE) pull

# network first: compose fails when the external network "edge" is missing. It is a no-op when it exists.
up: network
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=200 $(s)

deploy:
	@test -n "$(s)" || (echo "usage: make deploy s=<service>" && exit 1)
	$(COMPOSE) pull $(s)
	$(COMPOSE) up -d --no-deps $(s)

# validate first, reload only if valid. Never restart Caddy: a bad file would stop Magus too.
caddy-install:
	cp jbh.caddy $(CADDY_SITES_DIR)/jbh.caddy
	docker exec $(MAGUS_CADDY_CONTAINER) caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
	docker exec $(MAGUS_CADDY_CONTAINER) caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

# Consul publishes no host port. Tunnel to the container IP from your laptop instead.
consul-tunnel:
	@ip=$$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $$($(COMPOSE) ps -q jbh-consul)); \
	echo "On your laptop: ssh -L 8500:$$ip:8500 <user>@<vps>   then open http://localhost:8500"

backup:
	./backup-db.sh

config:
	$(COMPOSE) config -q && echo "compose.yaml OK"
