#!/bin/sh
# Daily dump of both JBH databases. Run from the jbh-deploy folder (cron: see README.md).
# Keeps 14 days in backups/. Copying backups/ off the VPS is a separate step: a backup on the
# same disk does not survive a lost VPS.
set -eu

cd "$(dirname "$0")"

mkdir -p backups
stamp=$(date +%Y-%m-%d)

for db in jbh jbh_finance; do
	# POSTGRES_USER is read inside the container, so this script never parses .env.
	docker compose --env-file .env -f compose.yaml exec -T jbh-postgres \
		sh -c "pg_dump -U \"\$POSTGRES_USER\" -Fc $db" > "backups/$db-$stamp.dump"
done

find backups -name '*.dump' -mtime +14 -delete
