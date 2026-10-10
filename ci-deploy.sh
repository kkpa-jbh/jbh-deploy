#!/bin/sh
# Deploys or rolls back one service, then waits until it is healthy. Two callers, one path:
# - the Deploy workflow: forced command of the CI deploy key (~/.ssh/authorized_keys, DEPLOY.md §1.1).
#   That key can run only this script. SSH puts the sent text ("deploy jbh-web") in SSH_ORIGINAL_COMMAND.
# - make deploy / make rollback on the VPS: the same text as arguments.
#
# deploy:   pull the newest image and restart. If it is not healthy, start the image from before by itself.
#           After a healthy deploy, the image from before is kept as the local tag <service>:previous.
# rollback: start <service>:previous (the image that ran before the last deploy).
# A failed deploy always exits red, even when the rollback worked.
set -eu

cd "$(dirname "$0")"

cmd="${SSH_ORIGINAL_COMMAND:-$*}"
action="${cmd%% *}"
service="${cmd#* }"

refuse() {
	echo "Refused: '$cmd'. Use: deploy|rollback jbh-web|jbh-gateway|jbh-iam|jbh-personal-finance" >&2
	exit 2
}

# Never Postgres or Consul: a restart there stops every service. Keep in sync with .github/workflows/deploy.yml.
case "$action" in
	deploy | rollback) ;;
	*) refuse ;;
esac
case "$service" in
	jbh-web | jbh-gateway | jbh-iam | jbh-personal-finance) ;;
	*) refuse ;;
esac

compose() {
	docker compose --env-file .env -f compose.yaml "$@"
}

container_id() {
	compose ps -a -q "$service"
}

# Image ID of the service's container. Empty when there is no container yet.
running_image() {
	cid=$(container_id)
	if [ -n "$cid" ]; then
		docker inspect -f '{{.Image}}' "$cid"
	fi
}

# 36 × 5 s = 3 minutes. The JVMs need 1–2 minutes. jbh-web has no healthcheck: "running" with no restart is enough there.
wait_healthy() {
	cid=$(container_id)
	state=missing
	i=0
	while [ -n "$cid" ] && [ "$i" -lt 36 ]; do
		sleep 5
		state=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else if gt .RestartCount 0}}restarting{{else}}{{.State.Status}}{{end}}' "$cid")
		case "$state" in
			healthy | running)
				echo "$service is $state."
				return 0
				;;
			unhealthy | restarting | exited | dead) break ;;
		esac
		i=$((i + 1))
	done
	echo "$service is not healthy (state: $state). Last 50 log lines:" >&2
	compose logs --tail=50 "$service" >&2
	return 1
}

# The image compose starts for the service, e.g. ghcr.io/kkpa-jbh/jbh-web:latest.
# config --images also lists the services it depends on, so keep only its own line.
ref=$(compose config --images "$service" | grep "/$service:" || true)
if [ -z "$ref" ]; then
	echo "Cannot read the image of $service from compose.yaml and .env (see the error above, if any)." >&2
	exit 1
fi

# Points the compose tag at an image that is already on the VPS, then restarts only this service. No pull.
start_image() {
	docker tag "$1" "$ref"
	compose up -d --no-deps "$service"
}

deploy() {
	old=$(running_image)
	compose pull "$service"
	if compose up -d --no-deps "$service" && wait_healthy; then
		new=$(running_image)
		if [ "$old" = "$new" ]; then
			echo "No new image: $service already ran the newest one."
		elif [ -n "$old" ]; then
			docker tag "$old" "$service:previous"
		fi
		return 0
	fi

	# The pull moved the tag, but the old image stays on the VPS until a prune.
	if [ -z "$old" ] || [ "$old" = "$(running_image)" ]; then
		echo "No other image to go back to (first start, or the image did not change)." >&2
		return 1
	fi
	echo "Rolling back $service to the image from before this deploy." >&2
	if start_image "$old" && wait_healthy; then
		echo "Rolled back: $service runs the image from before this deploy." >&2
	fi
	return 1
}

rollback() {
	if ! docker image inspect "$service:previous" >/dev/null 2>&1; then
		echo "No previous image for $service yet. The next healthy deploy saves one." >&2
		return 1
	fi
	prev=$(docker image inspect -f '{{.Id}}' "$service:previous")
	if [ "$prev" = "$(running_image)" ]; then
		echo "$service already runs the previous image. Nothing to do. Deploy brings the newest one back."
		return 0
	fi
	start_image "$prev"
	wait_healthy
}

case "$action" in
	deploy) deploy ;;
	rollback) rollback ;;
esac
