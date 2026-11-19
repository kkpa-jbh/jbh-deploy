## Overview

No test blueprint: the user excluded unit tests. The checks E1 to E12 in design.md are run by the leader.
T1 to T4 touch different files. T2 and T3 only use the command line fixed in design.md D1 and D7, so they need no output from T1.

## 1. Script (no dependency)

- [x] 1.1 `local-swap-env.sh`: move the jq rules into `JQ_RULES`, add `entries($svc)`, add `SWAPPABLE` and `EXCLUDED_KEYS` (with the why-comment). Print mode keeps its output (D1).
- [x] 1.2 `local-swap-env.sh`: add `union_lines` (D2), `report_conflicts` (D3), `write_env_file` (D4), `write_all`, `print_one`, and the `main` switch (D5). Update the header comment (new mode, the file holds real secrets).
- Depends on: none.

## 2. Make target (no dependency)

- [x] 2.1 `local.mk`: add `local-ide-env` to `.PHONY`; add the target with its comment, running `@sh ./local-swap-env.sh --write-all jbh.env` (D7).
- Depends on: none (command line fixed in design.md). Works only after 1.2.

## 3. Git ignore (no dependency)

- [x] 3.1 `.gitignore`: add `jbh.env`.
- Depends on: none.

## 4. Docs (no dependency)

- [x] 4.1 `LOCAL.md`: new section "Env file for the IDE (jbh.env)" with the IntelliJ steps, the profile note, the re-run note, the newer-IntelliJ line, the secret warning, and the Quarkus `ln -s` block with the `.gitignore` warning; one pointer from "Swap one service" step 1 (D7).
- [x] 4.2 `CLAUDE.md`: add `jbh.env` and `make local-ide-env` to the local-stack row of the files table.
- Depends on: none.

## 5. Checks (leader)

- [x] 5.1 Run E1 to E12 from design.md and the Complexity-Check command.
- Depends on: 1, 2, 3, 4.

Size estimate: 10 files, ~560 changed lines (tests and docs included)
