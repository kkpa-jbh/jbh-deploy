## ADDED Requirements

### Requirement: Docs describe the IDE env file
`LOCAL.md` SHALL tell the reader to run `make local-ide-env` and give the IntelliJ steps: install the EnvFile plugin; Run, Edit Configurations, tab EnvFile, Enable, `+`, `.env file`,
the path of `jbh.env`; set the profile in the run configuration (IAM: `local`); run `make local-ide-env` again and restart after `compose.local.yaml` changes.
It SHALL say that `SPRING_PROFILES_ACTIVE` is not in the file, that newer IntelliJ versions may load an env file without the plugin, and that `make local-swap` still prints the masked values of one service.
It SHALL show `ln -s` for `jbh-personal-finance` and `jbh-notification` (Quarkus reads `.env`), with a warning to check that the repo's `.gitignore` covers `.env`, and SHALL say `jbh.env` holds real secrets.
`CLAUDE.md` SHALL list `jbh.env` and the `local-ide-env` target in its files table.
`compose.yaml`, `compose.local.yaml`, `.env.example`, `.env.local.example`, `Makefile`, `DEPLOY.md`, `README.md` and `.github/` SHALL NOT change.

#### Scenario: Reader sets up IntelliJ
- **WHEN** a reader looks in `LOCAL.md` for how to give a service its env vars in IntelliJ
- **THEN** the text says `make local-ide-env`, the EnvFile steps with the path of `jbh.env`, and that the profile is set in the run configuration

#### Scenario: Reader links a Quarkus repo
- **WHEN** a reader looks in `LOCAL.md` for the Quarkus `.env`
- **THEN** the text has the `ln -s` command and the `.gitignore` warning, and no make target for it

#### Scenario: Other files are untouched
- **WHEN** `git diff --stat main -- compose.yaml compose.local.yaml .env.example .env.local.example Makefile DEPLOY.md README.md .github` runs after the change
- **THEN** it prints nothing
