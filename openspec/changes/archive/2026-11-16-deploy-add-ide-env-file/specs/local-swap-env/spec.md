## MODIFIED Requirements

### Requirement: One source for the IDE env vars
`local-swap-env.sh <service>` SHALL print the `environment` of `<service>` from `docker compose --env-file ${LOCAL_ENV_FILE:-.env.local} -f compose.local.yaml config --format json`,
one `KEY=value` per line, sorted by key. `make local-swap s=<service>` SHALL call it and SHALL NOT hold env var values of its own.
`LOCAL.md` SHALL NOT list the env vars of a service; it SHALL tell the reader to run `make local-swap s=<service>`.
The script SHALL accept only `jbh-iam`, `jbh-personal-finance`, `jbh-notification` and `jbh-gateway` as a service, and the option `--write-all <file>`.
Both modes SHALL use the same translation rules (no second copy of the rules).

#### Scenario: IAM values for the IDE
- **WHEN** `env -u JBH_JWT_SECRET -u GEMINI_API_KEY -u POSTGRES_USER -u POSTGRES_PASSWORD LOCAL_ENV_FILE=.env.local.example sh ./local-swap-env.sh jbh-iam` runs
- **THEN** it prints 15 lines, including `DB_HOST=localhost`, `DB_PORT=5433`, `CONSUL_HOST=localhost`, `CONSUL_DISCOVERY_HOSTNAME=host.docker.internal`,
  `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14317` and `JBH_JWT_SECRET=<from .env.local>`

#### Scenario: Not a swappable service
- **WHEN** the script runs with `jbh-postgres`, or with no argument
- **THEN** it prints a short error on stderr, prints nothing on stdout and exits non-zero

#### Scenario: Missing env file or tool
- **WHEN** the env file does not exist, or `docker` or `jq` is not on the `PATH`
- **THEN** it prints a short error that names the file or the tool, and exits non-zero

## ADDED Requirements

### Requirement: One IDE env file for all swappable services
`local-swap-env.sh --write-all <file>` SHALL merge the `environment` of the four swappable services into one list of `KEY=value` lines, sorted by key,
and write it to `<file>`. A key with the same value in several services SHALL appear once. The key `SPRING_PROFILES_ACTIVE` SHALL NOT be in the file.
The values SHALL be translated with the same rules as the print mode, and SHALL NOT be masked.
`make local-ide-env` SHALL run `sh ./local-swap-env.sh --write-all jbh.env` and SHALL hold no env var value. `jbh.env` SHALL be git-ignored.
A relative `<file>` is relative to the `jbh-deploy` folder.

#### Scenario: The file for the example env
- **WHEN** `env -u JBH_JWT_SECRET -u GEMINI_API_KEY -u POSTGRES_USER -u POSTGRES_PASSWORD LOCAL_ENV_FILE=.env.local.example sh ./local-swap-env.sh --write-all <file>` runs
- **THEN** `<file>` has 33 lines, including `DB_PORT=5433`, `CONSUL_PREFER_IP=false`, `JBH_JWT_SECRET=change-me` and `DATABASE_PASSWORD=change-me`, and has no `SPRING_PROFILES_ACTIVE` line

#### Scenario: The target calls the script
- **WHEN** `make -n local-ide-env` runs
- **THEN** it prints `sh ./local-swap-env.sh --write-all jbh.env`

#### Scenario: The file is ignored by git
- **WHEN** `git check-ignore jbh.env` runs
- **THEN** it prints `jbh.env` and exits 0

### Requirement: A conflicting key stops the write
When one key has different values in two or more services, the script SHALL write nothing, SHALL leave an existing `<file>` as it was,
SHALL print on stderr a short message with the key and the service names only (never a value), and SHALL exit non-zero.

#### Scenario: Two services disagree
- **WHEN** `DATABASE_USERNAME` is `jbh_admin` in `jbh-notification` and `other` in `jbh-personal-finance`
- **THEN** stderr is `local-swap-env.sh: conflicting values for DATABASE_USERNAME in jbh-personal-finance,jbh-notification`, stdout is empty, and `<file>` is not created or changed

### Requirement: The IDE env file protects its secrets
The file SHALL hold real values, because the IDE needs them. It SHALL be created with mode 600, written to a temporary file in the same folder and then moved onto `<file>`,
and the temporary file SHALL be removed on any failure. On success the script SHALL print one line only: the path and the number of keys.
The unmasked content SHALL NOT reach stdout or stderr, and the script SHALL NOT use `set -x`.

#### Scenario: A real secret in the shell
- **WHEN** the script runs with `--write-all` and `JBH_JWT_SECRET=canary-jwt` and `POSTGRES_PASSWORD=canary-pg` in the shell environment
- **THEN** `<file>` holds `JBH_JWT_SECRET=canary-jwt`, stdout is one line, stderr is empty, neither holds `canary`, and the file mode is 600

#### Scenario: Bad arguments
- **WHEN** `--write-all` has no file, or the folder of `<file>` does not exist
- **THEN** it prints a short error on stderr (it names the folder in the second case), creates no file, and exits non-zero
