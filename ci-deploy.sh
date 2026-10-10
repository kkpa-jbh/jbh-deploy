#!/bin/sh
# Forced command of the CI deploy key (~/.ssh/authorized_keys on the VPS, see DEPLOY.md).
# That key can run only this script. The Deploy workflow sends one service name, and SSH puts it in
# SSH_ORIGINAL_COMMAND. The script deploys that service, then waits until it is healthy.
# A red exit makes the workflow red. Nothing rolls back on its own: DEPLOY.md §3.
set -eu

cd "$(dirname "$0")"

service="${SSH_ORIGINAL_COMMAND:-}"

# Never Postgres or Consul: a restart there stops every service. Keep in sync with .github/workflows/deploy.yml.
case "$service" in
	jbh-web | jbh-gateway | jbh-iam | jbh-personal-finance) ;;
	*)
		echo "Unknown service: '$service'" >&2
		exit 2
		;;
esac

make deploy s="$service"

cid=$(docker compose --env-file .env -f compose.yaml ps -q "$service")

# 36 × 5 s = 3 minutes. The JVMs need 1–2 minutes. jbh-web has no healthcheck, so "running" is enough there.
state=unknown
i=0
while [ "$i" -lt 36 ]; do
	sleep 5
	state=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")
	case "$state" in
		healthy | running)
			echo "$service is $state."
			exit 0
			;;
		unhealthy | exited | dead) break ;;
	esac
	i=$((i + 1))
done

echo "$service is not healthy (state: $state). Last 50 log lines:" >&2
docker compose --env-file .env -f compose.yaml logs --tail=50 "$service" >&2
exit 1
