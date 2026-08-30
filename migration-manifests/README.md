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
| `unassigned.txt` | open question — `domain.setting`, `cli` |
| `already-extracted.txt` | already living in a submodule; do not re-extract |

`daemon-commands.txt` and `daemon-agents.txt` are **empty and stay that way**. Their 92 rows
moved to `already-extracted.txt`, their 10 Flyway rows and `OtelEnvironment` to
`monolith-only.txt` (dropped rather than carried), and `assign.py` now short-circuits
`domain.agent` and `domain.command` to `daemon-done` so a rerun cannot silently re-adopt them.

Targets with a `.paths` file: `projects`, `workspaces`, `artifacts`, `ci`, `observability`,
`stt`. The two daemon targets had one and no longer do: `qits-commands` and
`qits-coding-agents` were reimplemented rather than replayed (migration-plan.md §3.3), so there
was no `filter-repo` to feed and a path list would have implied otherwise.

`gateway.txt` has no `.paths` file for the same reason. The nine files were **adapted**, not
replayed: `AuthController` became a raw Vert.x route (the gateway has no REST layer),
`QitsAuthPolicy` lost its root-path stripping, and the two variant config files were folded into
`application.properties`. A `filter-repo` path list would have promised a history replay that did
not happen.

**`auth/` is no longer unassigned.** Authentication terminates at `qits-gateway`; the services
consume a header and authenticate nothing. So the 33 `auth/` files split three ways rather than
fanning out: 9 to the gateway, forwardauth's 3 duplicated per service, and 21 monolith-only — the
variant poms, the `package-info` describing the `-Dqits.variant` contract, and every variant test
suite, all of which exist to serve the build-time mechanism this decision deletes rather than moves.
`service/…/security/ForwardAuthVariantTest.java` joins them for the same reason.

## Regenerating

```sh
cd ../qits
git ls-files domain service artifacts epics ci auth cli \
             workspace-daemon workspace-daemon-protocol userflows qits-userflows \
  | grep -v 'service/src/main/webui/' > all.txt
python3 ../qits-qits/migration-manifests/assign.py all.txt   # prints per-target counts
```

`assign.py` is an ordered first-match ruleset. It exits with an `UNCLASSIFIED` list if
any path falls through — that list must stay empty. It reads `all.txt` from the working
directory, or a path given as its first argument; it writes per-target files into
`manifests/` beside wherever it ran, which are then reconciled by hand against the
files here.

Last run: **926 / 926 classified, nothing unclassified.**

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
- `DAEMON_MOVED` lists classes that left `WS_REPO` for `components/qits-workspaces/qits-workspace-daemon`
  (file browsing, framework detection). They are listed rather than deleted so that a
  rerun cannot silently re-adopt them.
- **Basename matching is unsafe on these manifests.** `workspace-daemon-protocol/` is
  vendored into two submodules and collides on names like `BootstrapOutcome`, and a shared
  basename can be an unrelated class — the daemon's in-container `ServiceSupervisor` versus
  the host-side projection of the same name. Exclude vendored trees and confirm identity
  before concluding a file is already extracted.
- Flyway migrations are assigned by the `MIG` table in `assign.py`; several touch more
  than one target and the `.txt` reason column records the secondary ones.
