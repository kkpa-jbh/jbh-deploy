#!/bin/sh
# Backs up or restores the databases of the local stack (jbh, jbh_finance) in the jbh-postgres container.
# Local only. Called by `make local-db-backup` and `make local-db-restore d=<dir>` (see LOCAL.md).
#   backup           -> backups/local/<UTC time>/<db>.dump (pg_dump custom format)
#   restore <dir>    -> takes a backup first, stops the services that use the DB, restores, starts them again
# POSTGRES_USER is read inside the container, so this script never parses .env.local.
set -eu

cd "$(dirname "$0")"

DBS="jbh jbh_finance"
# Services that hold connections to the DB. jbh-gateway has no DB.
DB_SERVICES="jbh-iam jbh-personal-finance jbh-notification"
BACKUP_ROOT=backups/local
COMPOSE="docker compose --env-file .env.local -f compose.local.yaml"

# Dumps hold user data. Only you may read them.
umask 077

running_services() {
  $COMPOSE ps --status running --services
}

check_postgres() {
  running_services | grep -qx jbh-postgres || {
    echo "jbh-postgres is not running. Start it: make local-up"
    exit 1
  }
}

# Prints the snapshot folder on the last line, so restore can name it.
backup() {
  check_postgres
  dir="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
  # Write to a .partial folder first: a failed dump never looks like a good snapshot.
  mkdir -p "$dir.partial"
  for db in $DBS; do
    $COMPOSE exec -T jbh-postgres sh -c "pg_dump -U \"\$POSTGRES_USER\" -Fc $db" > "$dir.partial/$db.dump"
  done
  mv "$dir.partial" "$dir"
  echo "Backup ready: $dir"
}

# A service run from the IDE still holds connections, and the restore would wait on its locks.
# jbh_monitor (Alloy) only reads statistics, so it does not count.
check_no_connections() {
  for db in $DBS; do
    n=$($COMPOSE exec -T jbh-postgres sh -c "psql -U \"\$POSTGRES_USER\" -d postgres -tAc \
      \"select count(*) from pg_stat_activity where datname = '$db' and usename <> 'jbh_monitor' and pid <> pg_backend_pid()\"")
    if [ "$n" != "0" ]; then
      echo "$n open connection(s) to $db. Stop the service in your IDE, then run the restore again."
      return 1
    fi
  done
}

restore() {
  src=${1:-}
  if [ -z "$src" ]; then
    echo "usage: make local-db-restore d=$BACKUP_ROOT/<snapshot>"
    ls -1 "$BACKUP_ROOT" 2>/dev/null | grep -v '\.partial$' || true
    exit 1
  fi
  for db in $DBS; do
    [ -f "$src/$db.dump" ] || { echo "Missing $src/$db.dump"; exit 1; }
  done
  check_postgres

  echo "Safety backup of the current data first."
  backup

  # Stop only the services that run now, and start only those again. A service swapped to the IDE stays stopped.
  stopped=""
  for s in $(running_services); do
    case " $DB_SERVICES " in *" $s "*) stopped="$stopped $s" ;; esac
  done
  if [ -n "$stopped" ]; then
    # shellcheck disable=SC2086
    $COMPOSE stop $stopped
    # shellcheck disable=SC2086
    trap "$COMPOSE start $stopped" EXIT
  fi

  check_no_connections
  for db in $DBS; do
    # --single-transaction: a failed restore changes nothing. --no-owner: objects belong to the current POSTGRES_USER.
    $COMPOSE exec -T jbh-postgres sh -c \
      "pg_restore -U \"\$POSTGRES_USER\" -d $db --clean --if-exists --no-owner --single-transaction" < "$src/$db.dump"
    echo "Restored $db from $src"
  done
}

case "${1:-}" in
  backup) backup ;;
  restore) restore "${2:-}" ;;
  *) echo "usage: $0 backup | restore <snapshot dir>"; exit 1 ;;
esac
