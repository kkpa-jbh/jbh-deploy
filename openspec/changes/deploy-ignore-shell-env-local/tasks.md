## 0. Test blueprint

No unit tests in this change (excluded by the user). No blueprint group. The checks C1 to C15 in design.md are run by the leader.

## 1. local.mk (independent)

- [ ] 1.1 Add `LOCAL_ENV_KEYS` and `LOCAL_CLEAN_ENV` (design D1), recursive `=`, with a comment that says why (shell exports must not win over `.env.local`).
- [ ] 1.2 `LOCAL_COMPOSE` starts with `$(LOCAL_CLEAN_ENV)`.
- [ ] 1.3 Add `IDE_ENV_FILE ?= jbh.env`. `local-ide-env` runs `@$(LOCAL_CLEAN_ENV) sh ./local-swap-env.sh --write-all $(IDE_ENV_FILE)`.
- [ ] 1.4 `local-swap` runs the script as `$$($(LOCAL_CLEAN_ENV) sh ./local-swap-env.sh $(s))`. `local-pg-monitor` stays as it is (D2).
- Files: `local.mk`. Depends on: nothing.

## 2. local-swap-env.sh header (independent)

- [ ] 2.1 Add two comment lines to the header (D3). No other change.
- Files: `local-swap-env.sh`. Depends on: nothing.

## 3. LOCAL.md (independent)

- [ ] 3.1 Add the note: `make local-*` ignores shell exports of the keys in `.env.local.example`; edit `.env.local` (D5).
- [ ] 3.2 Add the volume warning with the two fixes, and say that the second one deletes data (D5).
- Files: `LOCAL.md`. Depends on: nothing.

## 4. Checks (leader)

- [ ] 4.1 Run C1 to C15 from design.md. Depends on: 1, 2, 3.
- Suite commands: none besides the checks. The `Complexity-Check` of `CLAUDE.md` (both `compose ... config -q`) is C8.

Size estimate: 8 files, ~170 changed lines (tests and docs included)
