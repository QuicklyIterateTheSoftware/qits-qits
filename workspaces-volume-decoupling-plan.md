# Remove the shared git volume from qits-workspaces

Status: **SHIPPED AND VERIFIED, 2026-08-05.** SV-a landed as qits-workspaces `3d440c1`;
SV-b cut over the same day (run-args edited, qits-cd restarted, container `c9327580`
mounts only its own volume); SV-c verified live: workspace create/discard round-trip
pushed a branch to the git host and removed it again over HTTP, sidecars written and
deleted on the own volume, mirror-local ahead/behind and conflict preview working.

The user's decision: every technical process clones its own repository over HTTP, makes its
local changes, pushes them, and cleans up. No shared volume. This is the workspaces half of
that decision; qits-projects' half shipped earlier (projects-volume-decoupling-plan.md, BT).

## What is already true (measured on the live platform, 2026-08-05)

The architecture the decision asks for is **already implemented and deployed**. The live
qits-workspaces container runs `main` (`fdfc01b`), which carries the `gitmirror/` module:

- A private mirror per repository under `qits.workspaces.data-dir` (`/data/workspaces` on the
  service's own volume): `git clone --mirror` over HTTP on first use, `git fetch --prune` to
  refresh, per-operation detached worktrees that are `AutoCloseable`-cleaned.
- **Every ref write is a push** over HTTP: branch create, the three branch-delete flows, merge,
  and the release's `--atomic` main-plus-tag push. Post-receive fires for all of them, so CI
  sees every write. Nothing writes to `/data/repositories`.
- The mirror is a cache: delete it and the next request re-clones.

Exactly one production code path still *reads* the shared volume: the legacy fallback in
`WorkspaceMetadataStore` (read at `:63`, second delete at `:80`), kept for workspaces whose
metadata sidecar predates the move to the own volume.

**The removal precondition is met.** Measured today: the shared volume holds zero
`workspace_*.json` files (its 32 metadata files are all qits-projects' inert
`repository.json` leftovers), and both existing workspaces have their sidecars in the new
location on the own volume. The fallback can never fire again.

## Remaining work

### SV-a — delete the vestige in qits-workspaces

- `WorkspaceMetadataStore`: drop `legacyDataDir`, the read fallback, the legacy delete, and
  `legacyMetadataDir`.
- `domain/.../microprofile-config.properties`: drop `qits.repositories.data-dir` and its
  comment block.
- `docker/Dockerfile`: drop `mkdir -p /data/repositories` and
  `ENV QITS_REPOSITORIES_DATA_DIR`; rewrite the header that names the two mount reasons.
- Tests (41 files touch the old key): introduce a test-only `qits.test.origins-dir` for the
  fixture bares (`TestOrigin`, `FakeGitHostAddress`, `FakeContainerRuntime`,
  `FakeWorkspaceBootstrapDriver`), instead of reusing a production key that no longer exists.
- Delete `GitExecutor` (production-dead; only tests inject it) and the vestigial
  `WorkspaceService.workspacePathForBranch` whose javadoc still describes filesystem ref
  updates.

### SV-b — deployment cutover (home repo + live platform)

- `qits-local-up.sh`: drop `-v qits-repositories:/data/repositories` from
  `qits.cd.run-args.qits-workspaces` (the artifacts entries keep the volume — the git host
  owns it, and once workspaces lets go it is no longer *shared*).
- Live: edit the same line in `application.properties` on the `qits-cd-config` volume,
  restart qits-cd (it caches run-args at boot), then let the SV-a push's pipeline deploy
  qits-workspaces — the fresh container starts without the mount.

### SV-c — verify live

- The new container's mounts show no `qits-repositories`.
- Workspace create → merge → release passes on a real repository.
- A branch create/delete produces a post-receive (CI already sees them today; re-confirm).
- Sidecar write/read/delete works from the own volume only.

## Rollback note

After SV-b, images older than the mirror architecture can no longer be deployed for
qits-workspaces (they would look for `/data/repositories` and find nothing). That floor is
acceptable and consistent with platform practice: roll forward, not back.

## Out of scope

- The DFS/blob storage flip (git-host-storage-unification-plan.md) — stays a separate,
  pending decision. This plan completes its precondition AT for workspaces.
- The 32 stale `repository.json` files on the git host's volume — inert; a later
  qits-artifacts housekeeping pass may delete them.
- qits-artifacts' own mount of `qits-repositories` — that volume *is* the file-backend git
  host's storage, not a shared surface, once workspaces stops mounting it.
