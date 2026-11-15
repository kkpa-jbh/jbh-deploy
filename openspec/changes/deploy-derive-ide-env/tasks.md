## Test blueprint

No unit tests (the user excludes them) and no blueprint group. Verification is static: design.md "Test contract" V1 to V15. The leader runs them.

## 1. Script

Depends on: nothing.

- [x] 1.1 `local-swap-env.sh` (new, POSIX sh, `set -eu`): header comment (what, who calls it, `LOCAL_ENV_FILE`); `fail`, `check_args`, `check_tools_and_file`, `render_json`, `to_ide_lines` with the jq filter (translation rules and masking inside the filter, a comment per rule); `EXTRA_SECRET_KEYS=""`; stderr of docker and jq to `/dev/null`; JSON only in a shell variable (D1 to D5).

## 2. Make target

Depends on: 1 (script name and contract).

- [x] 2.1 `local.mk`: keep the usage and `LOCAL_SWAPPABLE` checks; render with the script before `stop`; print the header, the lines and the Consul/restore line; remove the echo lines and the `case` block (D6, D7).

## 3. Docs

Depends on: 1 (the output the docs describe). Independent of 2 (separate files).

- [x] 3.1 `LOCAL.md`: remove the env var table and the OTLP block; step 1 of "Swap one service" says what `make local-swap` prints; keep the why-ports-differ note, the 401 line and the Alloy metrics note (D8).
- [x] 3.2 `CLAUDE.md`: add `local-swap-env.sh` to the local-stack row of the files table (D9).

## 4. Verification (leader)

Depends on: 1, 2, 3.

- [ ] 4.1 Run V1 to V15 from design.md. Never start a container.

Size estimate: 10 files, ~400 changed lines (tests and docs included)
