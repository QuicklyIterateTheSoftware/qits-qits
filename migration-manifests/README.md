# migration-manifests

Generated file-level assignment backing [`../migration-plan.md`](../migration-plan.md).
Every tracked file under `../qits` (minus `service/src/main/webui/` and `target/`) is
listed exactly once across these files — **926 total**.

**These are copy lists, not move lists.** The monolith is never modified (see
migration-plan.md §1) and keeps all 926 files. A path appearing in `projects.txt`
means qits-projects should receive a copy of it, not that it leaves `../qits`.

| File | Meaning |
|---|---|
| `<target>.txt` | `path<TAB>reason` — the assignment, human-readable |
| `<target>.paths` | just the paths — input to `git filter-repo --paths-from-file` |
| `duplicated.txt` | copied to more than one target (see migration-plan.md §5) |
| `monolith-only.txt` | no target wants a copy; exists only in `../qits` |
| `unassigned.txt` | open question — auth, `domain.setting`, `cli` |
| `already-extracted.txt` | already living in a submodule; do not re-extract |

Targets with a `.paths` file: `projects`, `workspaces`, `daemon-agents`,
`daemon-commands`, `artifacts`, `ci`, `observability`, `stt`.

## Regenerating

```sh
cd ../qits
git ls-files domain service artifacts epics ci auth cli \
             workspace-daemon workspace-daemon-protocol userflows qits-userflows \
  | grep -v 'service/src/main/webui/' > all.txt
python3 migration-manifests/assign.py          # prints per-target counts
```

`assign.py` is an ordered first-match ruleset. It exits with an `UNCLASSIFIED` list if
any path falls through — that list must stay empty. `SRC` at the top points at
`all.txt`; adjust when re-running.

## Caveats

- `.paths` entries are **current** paths. `git filter-repo --path` matches historical
  paths too, so add extra `--path` entries **on the command line** for files that moved —
  migration-plan.md §8 step 2 carries the full known-renames list, which now also covers
  `artifactory` → `artifacts`, the `service/` → `domain/` module move, `daemonproxy` →
  `serviceproxy`, and two-hop chains that need both old names. Verify with
  `git log --follow --name-status <file>`, and read the status letter: **only `R` is a
  rename — `C` is a copy**, which these modules produce constantly because they were
  written by copying a sibling module wholesale.
- `domain/repository` is the one package that genuinely splits (workspaces vs
  projects). Its per-class split is hardcoded in `WS_REPO` / `PROJ_REPO` in
  `assign.py` and mirrored in migration-plan.md §3.1–3.2 — change both together.
  **The `service/` side splits with it**, via the name rules in `classify()`. Matching the
  directory alone sent the whole boundary to projects and stranded 24 workspace-scoped
  files there with no other owner (fixed 2026-07-26).
- `DAEMON_MOVED` lists classes that left `WS_REPO` for `daemons/qits-workspace-daemon`
  (file browsing, framework detection). They are listed rather than deleted so that a
  rerun cannot silently re-adopt them.
- **Basename matching is unsafe on these manifests.** `workspace-daemon-protocol/` is
  vendored into two submodules and collides on names like `BootstrapOutcome`, and a shared
  basename can be an unrelated class — the daemon's in-container `ServiceSupervisor` versus
  the host-side projection of the same name. Exclude vendored trees and confirm identity
  before concluding a file is already extracted.
- Flyway migrations are assigned by the `MIG` table in `assign.py`; several touch more
  than one target and the `.txt` reason column records the secondary ones.
