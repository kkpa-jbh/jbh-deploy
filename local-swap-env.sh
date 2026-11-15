#!/bin/sh
# Prints the env vars of one local service as IDE values: one KEY=value per line, sorted by key.
# Source: compose.local.yaml, rendered with `docker compose config --format json`. Docker host names
# become Mac addresses, and secret values are replaced by "<from .env.local>".
# Called by `make local-swap s=<service>`, or by hand from this folder.
# Env: LOCAL_ENV_FILE (default .env.local). Needs docker and jq.
# The compose JSON can hold real secrets from your shell. It stays in a shell variable, is masked
# inside jq, and never reaches the terminal or a file. The script starts and stops nothing.
set -eu

cd "$(dirname "$0")"

ENV_FILE=${LOCAL_ENV_FILE:-.env.local}
# Extra keys to mask, space separated, when the name rule misses one. Empty today.
EXTRA_SECRET_KEYS=""

fail() {
  echo "local-swap-env.sh: $1" >&2
  exit 1
}

check_args() {
  case "${1:-}" in
    jbh-iam | jbh-personal-finance | jbh-notification | jbh-gateway) ;;
    *) fail "usage: local-swap-env.sh <jbh-iam|jbh-personal-finance|jbh-notification|jbh-gateway>" ;;
  esac
}

check_tools_and_file() {
  command -v docker >/dev/null 2>&1 || fail "docker not found on the PATH"
  command -v jq >/dev/null 2>&1 || fail "jq not found on the PATH (macOS: brew install jq)"
  [ -f "$ENV_FILE" ] || fail "env file $ENV_FILE not found (run: cp .env.local.example .env.local)"
}

# The result is held by the caller in a variable. Compose stderr is dropped: it can quote values.
render_json() {
  docker compose --env-file "$ENV_FILE" -f compose.local.yaml config --format json 2>/dev/null ||
    fail "docker compose config failed (check: docker compose --env-file $ENV_FILE -f compose.local.yaml config -q)"
}

# Reads the JSON on stdin. $1 is the service. The jq filter has one def per rule.
to_ide_lines() {
  jq -r --arg svc "$1" --arg extra "$EXTRA_SECRET_KEYS" '
    # Secret by key name, or by the explicit list. Case sensitive: compose keys are upper case.
    def secret($k): ($k | test("SECRET|PASSWORD|PASS|API_KEY|TOKEN")) or ($extra | split(" ") | index($k) != null);

    # Host:port map. Alloy publishes OTLP on 14317 (the LGTM owns 4317).
    # The Postgres container publishes 5433 (the Mac Postgres owns 5432).
    # The gateway port is published, so the URL needs no /etc/hosts entry.
    def host:
      gsub("jbh-alloy:4317"; "localhost:14317")
      | gsub("jbh-postgres:5432"; "localhost:5433")
      | gsub("host.docker.internal:8080"; "localhost:8080");

    # IAM has host and port in two keys, so the map cannot do it: add DB_PORT here.
    def add_db_port:
      if any(.[]; .key == "DB_HOST" and .value == "jbh-postgres")
      then . + [{key: "DB_PORT", value: "5433"}] else . end;

    # Whole-key rules first. Consul publishes 8500, so the host is localhost.
    # CONSUL_DISCOVERY_HOSTNAME stays as rendered: every service registers host.docker.internal on purpose.
    def translate:
      if .key == "DB_HOST" and .value == "jbh-postgres" then .value = "localhost"
      elif .key == "CONSUL_HOST" and .value == "jbh-consul" then .value = "localhost"
      else .value |= host end;

    # A non-empty secret is masked. An empty one prints empty, so an unset key stays visible.
    def mask: if .value != "" and secret(.key) then .value = "<from .env.local>" else . end;

    (.services[$svc].environment // error("no environment"))
    | to_entries
    | map(.value |= (. // "" | tostring))
    | add_db_port
    | map(translate | mask)
    | sort_by(.key)
    | .[]
    | "\(.key)=\(.value)"
  '
}

main() {
  check_args "$@"
  check_tools_and_file
  json=$(render_json) || exit 1
  lines=$(printf '%s' "$json" | to_ide_lines "$1" 2>/dev/null) ||
    fail "could not read the environment of $1 from the rendered compose file"
  printf '%s\n' "$lines"
}

main "$@"
