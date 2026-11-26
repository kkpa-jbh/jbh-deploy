# Local Kubernetes cluster (k3d), see LOCAL-K8S.md. Included by the Makefile.
# For your machine only. It never touches the VPS or the Compose stack (make local-up).
#
# k3d runs a small Kubernetes (k3s) inside Docker containers. One cluster named "jbh":
# - laptop port 8081 -> the k3s Ingress controller (Traefik, port 80)  -> http://localhost:8081
# - the Docker volume jbh-k8s-pgdata -> /var/lib/jbh/pgdata in the k3d node (Postgres data, k8s/overlays/local/postgres-pv.yaml)

K8S_CLUSTER  = jbh
K8S_OVERLAY  = k8s/overlays/local
K8S_ENV_FILE = $(K8S_OVERLAY)/.env.k8s
K8S_PGVOLUME = jbh-k8s-pgdata
# The Postgres image's "postgres" user and group (k8s/components/postgres/statefulset.yaml runs as 70:70).
K8S_PGUSER   = 70:70
# The overlay reads initdb/ from outside its folder, so Kustomize must allow it.
K8S_RENDER   = kubectl kustomize --load-restrictor LoadRestrictionsNone $(K8S_OVERLAY)

.PHONY: k8s-up k8s-down k8s-reset-db k8s-pin k8s-status k8s-render k8s-ghcr-secret k8s-pg-monitor

# Creates the cluster if it does not exist, then applies every object and waits until all pods are Ready.
# Run it again after "make k8s-pin" (or after any change in k8s/): Kubernetes changes only what differs.
k8s-up:
	@test -f $(K8S_ENV_FILE) || (echo "Missing $(K8S_ENV_FILE). Run: cp $(K8S_OVERLAY)/.env.k8s.example $(K8S_ENV_FILE) and fill it." && exit 1)
	@# The data volume lives outside the cluster, so it survives k8s-down. Postgres (user 70) must own it,
	@# because the pod runs without root and cannot change the owner itself. A one-off Alpine container does it.
	@docker volume inspect $(K8S_PGVOLUME) >/dev/null 2>&1 || ( \
		docker volume create $(K8S_PGVOLUME) >/dev/null && \
		docker run --rm -v $(K8S_PGVOLUME):/data alpine:3.20 chown $(K8S_PGUSER) /data && \
		echo "Created the Docker volume $(K8S_PGVOLUME) for the Postgres data." )
	@k3d cluster list $(K8S_CLUSTER) >/dev/null 2>&1 || \
		k3d cluster create $(K8S_CLUSTER) \
			--port "8081:80@loadbalancer" \
			--volume "$(K8S_PGVOLUME):/var/lib/jbh/pgdata@server:0" \
			--wait
	@# The namespace first, then the image pull Secret, so the first pods can already pull the private images.
	kubectl apply -f k8s/base/namespace.yaml
	@bash scripts/k8s-ghcr-secret.sh jbh
	$(K8S_RENDER) | kubectl apply -f -
	@# Wait for each rollout, not for each pod: during a rollout the old pods of the replaced version are still listed,
	@# never become Ready, and would make a plain "kubectl wait pods --all" time out although the new pods run fine.
	@for r in $$(kubectl get deployment,statefulset -n jbh -o name); do \
		kubectl rollout status "$$r" -n jbh --timeout=5m || exit 1; \
	done
	@echo "JBH runs on http://localhost:8081"

# Deletes the cluster. The Postgres data stays in the Docker volume $(K8S_PGVOLUME).
k8s-down:
	k3d cluster delete $(K8S_CLUSTER)
	@echo "Cluster deleted. The Postgres data is kept (Docker volume $(K8S_PGVOLUME)). make k8s-reset-db deletes it."

# Deletes the cluster AND the Postgres data. Asks first. The next k8s-up starts with empty databases.
k8s-reset-db:
	@printf "This deletes the local cluster and all its Postgres data (volume $(K8S_PGVOLUME)). Type yes to go on: "; \
		read answer; [ "$$answer" = "yes" ] || (echo "Stopped. Nothing deleted." && exit 1)
	-k3d cluster delete $(K8S_CLUSTER)
	-docker volume rm $(K8S_PGVOLUME)

# Writes the newest git SHA of each image into the overlay's "images:" (scripts/k8s-pin.sh). Then run make k8s-up.
k8s-pin:
	@bash scripts/k8s-pin.sh $(K8S_OVERLAY)/kustomization.yaml

# Creates or renews the Secret jbh-ghcr-pull: the token the cluster uses to pull the private GHCR images.
# Set GHCR_TOKEN (a token with only read:packages) first; without it, your gh token is used. See the script.
k8s-ghcr-secret:
	@bash scripts/k8s-ghcr-secret.sh jbh

# initdb runs only on an empty volume. On an existing $(K8S_PGVOLUME) volume, this creates the jbh_monitor role once
# (Postgres metrics, k8s/components/observability). Safe to run again. Needs JBH_PG_MONITOR_PASSWORD in $(K8S_ENV_FILE)
# and a "make k8s-up" after you added it, so the pod has the value.
k8s-pg-monitor:
	kubectl exec -n jbh jbh-postgres-0 -c postgres -- sh /docker-entrypoint-initdb.d/02-create-monitor-role.sh

# Pods, Services and the Ingress of JBH, with their state.
k8s-status:
	kubectl get pods,svc,ingress -n jbh

# Prints the final YAML that k8s-up applies. Good for learning and for review. Starts nothing.
k8s-render:
	@$(K8S_RENDER)
