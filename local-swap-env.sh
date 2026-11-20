#!/bin/sh
# Two modes. Source of both: compose.local.yaml, rendered with `docker compose config --format json`.
# Docker host names become Mac addresses (same rules in both modes).
#   local-swap-env.sh <service>        prints the env vars of one service as IDE values, one KEY=value
#                                      per line, sorted by key. Secret values become "<from .env.local>".
#                                      Called by `make local-swap s=<service>`.
#   local-swap-env.sh --write-all <f>  merges the env of the four swappable services and writes it to <f>
#                                      (relative to this folder). Called by `make local-ide-env`.
#                                      THE FILE HOLDS REAL SECRET VALUES: mode 600, git-ignored, never commit.
# Env: LOCAL_ENV_FILE (default .env.local). Needs docker and jq.
# Through make (`make local-swap`, `make local-ide-env`), the shell exports of the keys in .env.local.example
# are removed first. Run by hand, the script reads your shell too.
# The compose JSON can hold real secrets from your shell. It stays in a shell variable and never
# reaches the terminal or a file. Only the final env file (write mode) holds values. The script starts
# and stops nothing.
set -eu

cd "$(dirname "$0")"

ENV_FILE=${LOCAL_ENV_FILE:-.env.local}
# Extra keys to mask, space separated, when the name rule misses one. Empty today.
EXTRA_SECRET_KEYS=""
# Services the IDE can run, in the order used in conflict messages.
SWAPPABLE="jbh-iam jbh-personal-finance jbh-notification jbh-gateway"
# Left out of the merged file, space separated. SPRING_PROFILES_ACTIVE would start the "local" profile in
# jbh-gateway too. JAVA_OPTS has a different heap cap per service. Each run configuration sets its own.
EXCLUDED_KEYS="SPRING_PROFILES_ACTIVE JAVA_OPTS"

# jq defs shared by both modes. A mode adds its own tail after them.
JQ_RULES='
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

  # The translated, not masked, environment of one service, as [{key, value}].
  def entries($svc):
    (.services[$svc].environment // error("no environment"))
    | to_entries
    | map(.value |= (. // "" | tostring))
    | add_db_port
    | map(translate);
'

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

# Print mode. Reads the JSON on stdin. $1 is the service. Values of secrets are masked.
to_ide_lines() {
  jq -r --arg svc "$1" --arg extra "$EXTRA_SECRET_KEYS" "$JQ_RULES"'
    entries($svc)
    | map(mask)
    | sort_by(.key)
    | .[]
    | "\(.key)=\(.value)"
  '
}

# Write mode. Reads the JSON on stdin. Values are real. One line per key, sorted by key:
# "KEY=value" when all services agree, "!KEY in svc1,svc2" when they differ (a "!" is never a key).
union_lines() {
  jq -r --arg extra "$EXTRA_SECRET_KEYS" --arg swappable "$SWAPPABLE" --arg excluded "$EXCLUDED_KEYS" "$JQ_RULES"'
    ($swappable | split(" ")) as $svcs
    | ($excluded | split(" ")) as $skip
    | [ $svcs[] as $s | entries($s)[] | {key, value, svc: $s} | select(.key as $k | $skip | index($k) == null) ]
    | group_by(.key)
    | .[]
    | (map(.value) | unique) as $vals
    | if ($vals | length) == 1
      then "\(.[0].key)=\($vals[0])"
      else "!\(.[0].key) in \(map(.svc) | join(","))" end
  '
}

# $1 is the union output. Only the "!" lines are printed: they hold a key and service names, never a value.
report_conflicts() {
  msgs=$(printf '%s\n' "$1" | sed -n 's/^!\(.*\)/local-swap-env.sh: conflicting values for \1/p')
  if [ -n "$msgs" ]; then
    printf '%s\n' "$msgs" >&2
    exit 1
  fi
}

# $1 is the target file, $2 the lines. The temporary file is in the same folder, so the move is
# atomic and keeps mode 600. The trap removes it on any failure; after a good move it does nothing.
write_env_file() {
  umask 077
  tmp=$(mktemp "$(dirname "$1")/.jbh-env.XXXXXX") || fail "could not create a temporary file in $(dirname "$1")"
  trap 'rm -f "$tmp"' EXIT
  trap 'exit 1' HUP INT TERM
  printf '%s\n' "$2" >"$tmp"
  mv "$tmp" "$1"
  count=$(printf '%s\n' "$2" | wc -l | tr -d ' ')
  echo "$1: $count keys"
}

write_all() {
  file=${1:-}
  [ -n "$file" ] || fail "usage: local-swap-env.sh --write-all <file>"
  dir=$(dirname "$file")
  { [ -d "$dir" ] && [ -w "$dir" ]; } || fail "folder $dir does not exist or is not writable"
  check_tools_and_file
  json=$(render_json) || exit 1
  lines=$(printf '%s' "$json" | union_lines 2>/dev/null) ||
    fail "could not merge the environments from the rendered compose file"
  [ -n "$lines" ] || fail "no environment found in the rendered compose file"
  report_conflicts "$lines"
  write_env_file "$file" "$lines"
}

print_one() {
  check_args "$@"
  check_tools_and_file
  json=$(render_json) || exit 1
  lines=$(printf '%s' "$json" | to_ide_lines "$1" 2>/dev/null) ||
    fail "could not read the environment of $1 from the rendered compose file"
  printf '%s\n' "$lines"
}

main() {
  case "${1:-}" in
    --write-all) write_all "${2:-}" ;;
    *) print_one "$@" ;;
  esac
}

main "$@"
