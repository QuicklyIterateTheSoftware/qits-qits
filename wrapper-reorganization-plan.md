# wrapper-reorganization: group repositories by component, not archetype

Status: **PHASES 1 AND 2 EXECUTED 2026-08-30.** The wrapper is `components/`, and ALL
44 renames are LIVE: 7 libs, 3 images + CLI, 15 frontends, 18 services — every repo in
the `<component>[-<modifier>]-<role>[-<tech>]` grammar. Final reconcile: 15 KEPT + 33
SYNC_TARGET_UPDATED, zero strays. Every service pins its deployed identity with
`application:` (hosts, databases, wire names unchanged). Outside the rename set, as
designed: qits-qits (the wrapper), the three daemons (already conformant), qits-spa-home
(archival pending). Phase 3 (blobstore merges into qits-registries) remains. Remaining
tails are under "Open items".

## Goal

Replace the archetype layout (`services/`, `daemons/`, `libs/`, `frontends/`, `cli/`,
`images/`) with one directory per technical component. A component is any cohesive unit —
it does not need a deployable. This reverses the role-directory doctrine in `CLAUDE.md`;
rewrite that section when phase 1 lands.

## Name grammar

    <component>[-<modifier>]-<role>[-<tech>]

- Roles: `service`, `frontend`, `daemon`, `oci`, `cli`, `javalib`, `jslib`.
- `platform` is a tier modifier before the role: `qits-deployments-platform-service`.
- Tech suffix only where the role alone is ambiguous (the lib pairs).
- Tech stays out of component names: `qits-database`, not `qits-postgresql` — the
  implementation may change, the component does not.
- Singular vs plural is semantic, not drift: `qits-workspaces` is the service that
  administers workspaces; `qits-workspace-daemon` / `qits-workspace-oci` ARE a workspace.

## The map

    components/qits-ci/             qits-ci-service, qits-ci-frontend, qits-ci-daemon
    components/qits-projects/       qits-projects-service, qits-projects-frontend, qits-projects-daemon
    components/qits-workspaces/     qits-workspaces-service, qits-workspaces-frontend,
                                    qits-workspace-daemon, qits-workspace-oci
    components/qits-artifacts/      qits-artifacts-service, qits-artifacts-frontend
    components/qits-githost/        qits-githost-service, qits-githost-frontend
    components/qits-configuration/  qits-configuration-service, qits-configuration-frontend
    components/qits-docs/           qits-docs-service, qits-docs-frontend
    components/qits-observability/  qits-observability-service, qits-observability-frontend
    components/qits-containers/     qits-containers-service
    components/qits-stt/            qits-stt-service

    components/qits-deployments/    qits-deployments-platform-service, qits-deployments-platform-frontend
    components/qits-events/         qits-events-platform-service,       qits-events-platform-frontend
    components/qits-idp/            qits-idp-platform-service,          qits-idp-platform-frontend
    components/qits-maintenance/    qits-maintenance-platform-service,  qits-maintenance-platform-frontend
    components/qits-mirror/         qits-mirror-platform-service,       qits-mirror-platform-frontend
    components/qits-orchestrator/   qits-orchestrator-platform-service, qits-orchestrator-platform-frontend
    components/qits-system/         qits-system-platform-service,       qits-system-platform-frontend
    components/qits-edge/           qits-edge-platform-service

    components/qits-registries/     qits-registries-javalib, qits-blobstore-javalib
    components/qits-eventstream/    qits-eventstream-javalib
    components/qits-integrations/   qits-integrations-quarkus-javalib, qits-integrations-angular-jslib
    components/qits-ui-components/  qits-ui-components-jslib
    components/qits-userflows/      qits-userflows-javalib
    components/qits-build-images/   qits-build-images-oci
    components/qits-database/       qits-database-oci
    components/qits-bootstrap/      qits-bootstrap-cli

Rename column (phase 2): `qits-spa-<x>` → `qits-<x>-frontend`,
`qits-platform-<x>` → `qits-<x>-platform-service`, `qits-platform-spa-<x>` →
`qits-<x>-platform-frontend`, `qits-oci` → `qits-build-images-oci`, `qits-oci-postgresql` →
`qits-database-oci`, `qits-oci-workspace` → `qits-workspace-oci`, `qits-spa-ui-components` →
`qits-ui-components-jslib`, `qits-cli-bootstrap` → `qits-bootstrap-cli`, libs get `-javalib`.
`qits-oci` needs no split: what remains after postgres and workspace is the five CI step
images, one release unit on purpose, already published as `qits/build-images/*`.

**`qits-spa-home` is not in the map.** It gets archived (open item from the per-service-hosts
campaign), not reorganized.

## Phases

**Phase 1 — component navigation + wrapper paths, names untouched.** The left navigation
grouped by component is THE point of the redesign: a component's repositories sit next to
each other instead of scattered across six archetype groups. Move every gitlink under
`components/` and edit the `path` in `.gitmodules`. Submodule NAMES stay the bare repo
names, so the platform catalog (which adopts by name) sees no change: rows, bares, CI
history, clone URLs, app identity all intact.

How the navigation works today (traced 2026-08-30):

- **qits-projects** derives each repository row's archetype from the wrapper directory —
  `RepositoryArchetype.fromDirectory`, "directory IS archetype, in both directions" — with
  the DB check constraint `CK_repository_archetype` behind it. The project template
  skeleton seeds new wrappers with the six directories, and repo creation places by
  archetype directory.
- **qits-spa-ui-components** owns the chrome: `QitsCategory` is the closed six-set, the
  sidebar draws one group per category, and the category is in the ADDRESSES —
  `/<project>/<category>/<repoName>/…`, parsed by a closed-set test (`scope.ts`).
- **qits-platform-edge** serves `/main-navigation` from the deployment projection and
  validates `navigation-entries` against its closed slot vocabulary: `system`, `platform`,
  `project.detail`, and six `<category>.details`.
- The six detail slots are NOT redundant: qits-configuration hangs only under
  services+daemons, qits-artifacts skips frontends+cli. The slots say which KINDS of repo
  get which child app — that is a use of archetype independent of the sidebar grouping.

What changes:

- **qits-projects**: DONE (9fec91cb, released 2026.830.82133). `component` column (V6,
  nullable, no constraint), `WrapperPath` reads both layouts, existing rows KEEP their
  archetype on a move and only gain the component; a minted row takes the name-suffix
  archetype, else NULL (deliberate: a null-archetype row is never offered the
  bare-destroying delete; the reconcile guards RepositoryService's null→SERVICE default).
  `component` on RepositoryDto + EntryOutcome; creation takes an optional component and
  follows the wrapper's layout; `components` reserved as a slug. DEFERRED on purpose:
  the project-template skeleton still seeds the six archetype dirs (moving it before the
  chrome ships would seed a layout the sidebar cannot group) — flip it with the wrapper.
  OPEN from this workstream: under the component layout nothing can change a row's
  archetype (the move-between-dirs mechanism dies with the flip; decide a PATCH or
  repository.yml override before phase 2); RepositoryMcpTools.RepositorySummary lacks
  `component`.
- **qits-spa-ui-components**: DONE (committed on main, 984eb33, unpushed/unreleased).
  Sidebar groups by `component ?? category`: component groups first alphabetically, then
  the still-populated legacy categories in canonical order — an unmigrated platform
  renders exactly today's six groups. URL design (closes the open item): `QitsScope`
  gained `group` (the middle segment, either spelling; `category` set only for the six),
  and `parseScope` takes an optional `knownComponents` set beside `knownSlugs` — the six
  categories prove segment two on their own, an open component segment is a group only
  when the known set has it. Backward compatible: 1-/2-arg `parseScope` calls compile
  and behave as before; chrome links prefer the component form; both forms resolve.
  Consumer contract for the SPA wave: read `scopeGroup(scope)` not `scope.category`;
  route guards must accept the open segment (pass components or use `QITS_SCOPE`);
  `QitsRepository.component?: string` is new-optional.
- **qits-platform-edge**: likely UNCHANGED — the archetype-keyed detail slots still
  express kind-scoped children. Verify during implementation; if slots do move, it is a
  projection-affecting edge change (mind the edge snapshot-replay rule).
- **`deployments.yml` sweep**: only if the slot vocabulary changes; otherwise untouched.
- The shells pick the chrome up via the ui-components release and the train.

Also in phase 1 (path audit completed 2026-08-30; full inventory in that session):

- **qits-cli-bootstrap: DONE** (committed on main, c581efa, unpushed). `.gitmodules` is
  the path authority now (`GitModules` parser; `PlatformModel.repoPath` demoted to
  cold-start fallback); wrapper detection covers both layouts; archetype derives from the
  legacy first segment, else name suffix, else a built-in name table; a declared module
  missing from a wrapper with ANY submodule checked out fails LOUD (the all-empty cold
  start keeps its org fallback); `HostLauncher` resolves both CLI paths and walks
  worktree gitdirs to depth 3. `qits-local-up.sh` edited (uncommitted, superproject's
  campaign commit). Found live: four `.gitmodules` entries carry STALE URLS
  (`qits-platform-{events,deployments}` and their spa twins still say
  `../qits-{events,deployments}.git` — the old pre-platform names, working only via
  GitHub rename redirects; the entry NAMES are correct). Those four were silently
  building from GitHub instead of local checkouts; the url-arm lookup fixes the build,
  and the wrapper flip updates the four urls to the current names. Also: when qits-spa-home is archived it must leave
  `PlatformModel.SEEDED_REPOS`, or an org copy nobody maintains gets built.
- **Seven routing SPAs share one break**: each guards `:project/:category/:repository`
  with a closed-set `QITS_CATEGORIES.includes(...)` test (spa-projects, -ci, -artifacts,
  -workspaces, -githost, -docs, -configuration). They adapt after the chrome ships its
  open-set mechanism. qits-spa-projects additionally holds the archetype→directory table
  (`COMPONENT_TYPES` in api/dto.ts), `format.ts wrapperDirectory`, and the
  create-repository page's destination preview.
- The maintenance train, workspaces, both provisioner daemons, and every `.config/qits`
  pipeline are path-agnostic — confirmed SAFE, keyed on names not paths.
- Relative submodule URLs (`../<name>.git`) resolve against the superproject REMOTE, not
  the gitlink path, so three-segment paths stay correct — but the reconcile's backup-URL
  fold needs a test proving it.
- Wrapper flip housekeeping: sweep the stale undeclared directories
  (`services/qits-gateway`, `services/qits-repositories`, the duplicate
  `integrations/qits-integrations-quarkus`) so the six old directories can be REMOVED
  outright — a leftover `services/qits-artifacts` would keep `WrapperDir` answering and
  mask bootstrap breakage during testing. Push the wrapper to the platform githost (the
  catalog IS the wrapper's `.gitmodules` there) and to GitHub.
- Docs sweep: the wrapper `CLAUDE.md` layout doctrine (the plan reverses it),
  `local-platform.md`, `reboostrapping.md`, `docs/project-setup-quinoa-angular.md`, the
  bootstrap CLI's own CLAUDE.md ("the wrapper directory" doctrine), and path mentions in
  ~10 repo AGENTS/READMEs.

Order inside phase 1: the qits-projects derivation change and the chrome must be released
BEFORE the wrapper flip, or the reconcile nulls archetypes and the sidebar has no
components to group by. The bootstrap CLI fix must be released (or at least committed)
before anyone bootstraps from a flipped wrapper. Wrapper flip last, one campaign.

**Phase 2 — renames, per repo, cheapest first.** There is no rename operation on the
platform today (grepped qits-projects and qits-githost, 2026-08-30), so phase 2 starts by
building one. The 2026-08-21 identity ruling makes it small: bares are UUID-keyed, the
name is metadata on the projects row, name-addressed reads resolve through that row.

Prerequisite builds, both small:

- **qits-projects rename endpoint: BUILT** (fd804082 + c448f664, release pending).
  `PATCH /projects/api/repositories/{repoId}` body `{name}` → `{repository,
  previousName, changed}`; refuses taken/illegal names and the wrapper row; publishes
  `RepositoryRenamed(projectId, repositoryId, oldName, newName, renamedAt)` after the
  tx. VERIFIED: no githost call (all verbs address the UUID; names resolve via the
  alias table — old aliases DROPPED, no redirect); backupUrl self-heals at the first
  reconcile after the `.gitmodules` push (`SYNC_TARGET_UPDATED`); the one window is the
  row reading UNDECLARED between the PATCH and the wrapper push (deliberate, tested).
  Archetype re-derives from a suffixed new name, suffix-less preserves. Creation's
  archetype is optional now (derived from the name suffix; neither → 400). The template
  seeds `components/README.md` teaching the grammar; the six dirs are gone from the
  skeleton while `fromDirectory` stays for legacy wrappers.
- **qits-platform-deployments `application:` override: BUILT** (committed, release
  pending). One optional key; absent = byte-identical to today; present = the name for
  EVERY derivation (verified: the name resolves once in RepositoryRef.applicationName
  and threads by value; substitution lives in one DeployService helper). Validation via
  PdIdentifiers.requireName. Edges: duplicate application names are LAST-WINS and
  logged (pd_service records no repository identity — refusing needs a storage-id
  column, follow-up); an unreadable spec falls back to the repository name; changing
  the value later = decommission + new app. ORDER: release the deployer BEFORE any
  repo writes `application:`. qits-workspaces is untouched (it only checks the file
  exists).

The per-repo runbook — ordering is what avoids the reconcile trap (reconcile adopts by
name, so a renamed `.gitmodules` entry would otherwise read as remove+add: new empty bare,
old row UNDECLARED, Delete destroys the bare). NEVER rename by migrate-and-delete:

1. Rename on the platform (the PATCH above).
2. Rename on GitHub: `PATCH /repos/QuicklyIterateTheSoftware/<repo>` — the workstation
   credential (GCM `gho_` token, `repo` scope, org admin, verified 2026-08-30) suffices,
   and GitHub leaves redirects.
3. Update every `.gitmodules` that names it — the wrapper, plus any embedding repo
   (qits-ci embeds qits-eventstream; every SPA-hosting service embeds its frontend repo as
   `service/src/main/webui`) — and push. Reconcile finds the new name already on the row:
   KEPT, no ghost.
4. Services additionally set `application:` to their old name in the same campaign.

Order: libs first (no `deployments.yml`, smallest consumer surface — the proving ground),
frontends next (plus the owning service's `.gitmodules`), services last (after the
`application:` override ships). Maven/npm coordinates are independent and stay put.

**LIB WAVE COMPLETE 2026-08-30 evening: all seven libs renamed and released green
under their new identities** (eventstream-, blobstore-, registries-,
userflows-javalib; integrations-angular-, integrations-quarkus-,
ui-components-jslib — the last was qits-spa-ui-components). Wrapper release
2026.830.132744, reconcile 42 KEPT + 6 SYNC_TARGET_UPDATED. Consumer matchers across
12 repos are COORDINATE-KEYED now (repository: conditions dropped where a packageName
existed) and PROVEN live: the integrations-quarkus release fired upstream-auth-core
green in ci/artifacts/deployments, and the automated service train wave followed.
Landed on platform mains via direct config-only pushes (-o qits.no-ci), not releases.
NOTE: "dead matcher" is per-repo EMPIRICAL, not pattern — ui-components' repoId
matcher was alive (mixed storage-id era); verify by measurement at each rename.
Remaining: images+cli (qits-build-images-oci, qits-database-oci, qits-workspace-oci,
qits-bootstrap-cli), frontends (+owning-service .gitmodules + upstream-spa matchers,
which have no coordinate and need the new names), services last (application: keys;
also settle the short-name rows qits-deployments/qits-events + qits-artifacts'
release matcher naming qits-platform-artifacts — verify each empirically).

**SPA bump-release mechanism, learned the hard way:** SPA repos release their
maintenance branches via the OLD prefix-gated step INSIDE `ci-post-receive.yml` —
they need NO `ci-event-maintenance-release.yml`, and adding one double-calls the
door (second call red on ALREADY_INTEGRATED). What the SPAs did get: readable bump
branch names (`maintenance/ui-components` instead of `maintenance/<uuid>` — the
event's `repository` field carries a storage id since the renames). Four SPAs have
NO chrome automation at all (docs, githost, mirror, configuration) — a later
fleet-completion batch.

**PROVEN 2026-08-30 on qits-eventstream → qits-eventstream-javalib** (both prerequisites
released and deployed: deployer 2026.830.122232, projects 2026.830.122821). Result:
reconcile 47 KEPT + 1 SYNC_TARGET_UPDATED, same UUID, zero UNDECLARED, new clone
address 200 / old 404, backupUrl healed to the renamed GitHub repo. Wrapper mechanics
for an entry rename: `git mv` the path, rewrite the `[submodule]` section name AND the
relative url, then per checkout type — gitfile checkouts need `.git/modules/<name>`
moved + the gitfile and `core.worktree` repointed; embedded-`.git` checkouts
(eventstream, platform-edge, oci-workspace) need only `remote set-url`. Wrapper release
through the door, then POST `/repositories/reconcile`. Consumers cloning from the
PLATFORM githost see no redirect (aliases are dropped!) — update consumer
`.gitmodules` promptly; GitHub-side consumers ride redirects meanwhile.

**The rename ripple is the `.config/qits` matchers, and the proving ground mapped them:**

- `repoId: { exact: <name> }` matchers (the four lib release pipelines: eventstream,
  blobstore, integrations-angular, integrations-quarkus) were LATENTLY DEAD since the
  2026-08-22 identity cutover — storage ids are UUIDs, the match never fired, those
  libs published NO release artifact since then, silently. Fix = `repoName: { exact:
  <new name> }` (SCMPublishTag carries it). PROVEN: eventstream-javalib's release
  pipeline fired green after the fix (2026.830.125350) — first lib artifact publish
  since the cutover. Fix the other three WITH their renames.
- `repository: { exact: <name> }` matchers (service release pipelines, upstream-spa
  files, upstream-eventstream/auth-core consumers) key the PUBLIC NAME off
  SCMRelease/SoftwareRelease — they break on rename and must be updated to the new
  name in the same campaign: the renamed repo's own release yml, every
  `ci-event-upstream-*` naming it (qits-ci + qits-deployments name qits-eventstream;
  the SPA upstream files name the qits-spa-* repos), and the maintenance files'
  `repoId: { exact: <service> }`... note those DO match today (verify against the
  event, same UUID caveat may apply per event type). `packageName` matchers key maven
  coordinates and are rename-proof.

**Phase 3 — merges, only after the reorg.**

- Fold qits-blobstore into the qits-registries repo and retire the blobstore repo. The
  split from qits-artifacts left `eu.wohlben.qits.artifacts` classes stranded in blobstore;
  the merge is where that gets fixed. Consumers (artifacts, githost, mirror) depend on the
  published jar, so this is repo plumbing, not a consumer campaign — keep the artifactId or
  bump it once, coordinated. Merged, blobstore rides qits-registries' releases: one version
  for the storage layer.

## Open items

- Phase 2 verifies: backup-sync's GitHub mapping key; where the deployer reads the
  application name off the build event.

## Phase 2 rulings (2026-08-30, user)

- **Archetype is determined by the name.** The rename endpoint re-derives the row's
  archetype from the new name's role suffix, so the renames ARE the archetype-change
  mechanism; a committed `repository.yml` archetype would also be an acceptable
  override. No separate PATCH-archetype operation.
- The template-skeleton reshape (deferred phase-1 tail) rides the rename-endpoint
  release in qits-projects.
- Creation stops requiring archetype: derived from the name suffix when absent.
- Phase 2 STARTED 2026-08-30: rename endpoint + skeleton (qits-projects) and the
  `application:` override (qits-platform-deployments) delegated in parallel.
- Archive qits-spa-home (independent of this plan, but ordered before it renames anything).
