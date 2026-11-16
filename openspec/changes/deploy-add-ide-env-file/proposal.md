## Why

To run a service from IntelliJ, the developer must set the same env vars in every run configuration. `make local-swap` prints them
per service, with secrets masked, so the developer copies them by hand. With four swappable services this is slow and error prone.
The values already come from one place, `compose.local.yaml`. One generated file can hold them all.

## What Changes

- `local-swap-env.sh` gets a new mode: `--write-all <file>`. It merges the env of `jbh-iam`, `jbh-personal-finance`, `jbh-notification`
  and `jbh-gateway` into one sorted `KEY=value` list, with real secret values, and writes it to `<file>`.
- `make local-ide-env` runs `sh ./local-swap-env.sh --write-all jbh.env`. The file `jbh.env` is in the `jbh-deploy` root and is git-ignored.
- `SPRING_PROFILES_ACTIVE` is left out (it would start the `local` profile in `jbh-gateway` too). The developer sets the profile in each run configuration.
- Same key, different values in two services: the script fails, writes nothing, and names the key and the services (never a value).
- The file has mode 600, is written atomically, and is removed on failure. Real values never reach stdout or stderr.
- `LOCAL.md` gets the IntelliJ EnvFile steps, and an `ln -s` example for the two Quarkus repos (docs only).
- `make local-swap` is unchanged: it still prints the masked values of one service.
- `.gitignore` ignores `jbh.env`. `CLAUDE.md` lists the new file and target.
- No change to `compose.local.yaml`, `compose.yaml`, `.env.local.example`, `README.md`, `Makefile`, `.github/`. No database change. Nothing outside `jbh-deploy` changes.

## Capabilities

### New Capabilities
none

### Modified Capabilities
- `local-swap-env`: the script has a second mode, the one IDE env file (union, exclusions, conflicts, secret handling).
- `deploy-docs`: `LOCAL.md` explains the IntelliJ EnvFile setup and the Quarkus `.env` link.

## Impact

Files: `local-swap-env.sh`, `local.mk`, `.gitignore`, `LOCAL.md`, `CLAUDE.md`. Local dev only. Needs `jq` and `docker`, as today.
Ticket JBH-56, branch `ft/CH3-JBH-56-deploy-add-local-pg-monitor`, PR #3. The archived decisions D1 to D9 and checks V1 to V15 of
`deploy-derive-ide-env` stay valid, except V13 (see design D6).
