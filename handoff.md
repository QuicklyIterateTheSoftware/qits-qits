# Handoff

What is still open. Everything shipped and closed is in git history; durable
lessons are in the memory files
(`~/.claude/projects/-home-wohlben-code-qits-qits/memory/`).

## Platform state

Full rebootstrap green 2026-08-13 ~17:30 (`unwrap --with-data-volumes` +
`QITS_SHIP_MAINS=1`): exit 0, 69 ok + 1 skip in 19m51s, 17/17 services healthy,
edge 200, every deployed sha = local main, all 24 CI repos green.

The fresh githost held ZERO release tags, and 16 repos' mains are ahead of their
newest release tag (deployments by 15 — the swarm migration). Consequence: a
plain restore-default boot ships stale code until a release wave has run through
this platform. Boot with `QITS_SHIP_MAINS=1`, or release first.

## In flight

Another session owns the lib calver campaign and edits this file — merge, do not
clobber.

### Plan-doc audit residue 2026-08-13 (what still needs a hand)

Sixteen implemented/superseded plan docs were removed (verdicts in the
removal commits; the nine kept docs each carry their own open work).
Actionable leftovers:

- Re-point on next touch of each repo: bootstrap-replay-plan named in
  qits-ci (AGENTS.md, CiRunService, ReleaseJoinTest) and
  qits-spa-ui-components README; event-delivery-guarantees-plan in
  ci/deployments AGENTS.md; artifacts-gc-plan ~8x left in artifacts Java
  javadoc + gc properties (README/AGENTS done 2026-08-13; V11's mention
  stays — applied migration, Flyway checksums comments);
  byte-plane-split-plan in githost/mirror READMEs (artifacts done);
  db-patience-plan ~11x (see Docs and prose).
- Defect register carried from the removed provisioning plan — verify
  each is still real before acting: eventstream subscriber restart
  fragility (docker-restarted containers never redial the bus),
  silent no-match in CI event triggers, SoftwareRelease still
  UUID-only, the SCMRelease-vs-upload pin race, a gitlink-reachability
  unwrap preflight.
- gateway-route-events-plan is schedulable now: its stated blocker
  (bus delivery reliability) shipped.
- migration-plan needs a staleness pass on next touch (items 7/8 are
  done but unmarked).

### artifacts→PostgreSQL campaign (started 2026-08-13 evening)

Executing `qits-artifacts-postgresql-plan.md`. User decisions today: go;
blob bytes into PG as the qits-blobstore lib's ONLY backend — the mirror
migrates too, no storage SPI. Discovery that reshapes it: qits-githost is
a THIRD BlobStore consumer (git packs via its PackBlobStore port,
precious data) — it stays on its exact pre-PG lib pin until its own WP.
Nothing merges to a releasable main until the cutover set is complete: a
blobstore release fires the calver train, and a ship-mains boot
seed-publishes lib mains, so all code WPs live on `postgres-blobs`
branches.

- C1 DONE on artifacts main (5fc69b3): `resources: postgresql:db` — the
  next deploy provisions role+database while the H2 image ignores the
  injected triple. Verify the pd_resource row after that deploy.
- WP-LIB in flight (agent): libs/qits-blobstore branch `postgres-blobs`,
  version 1.0.0-pgblobs-SNAPSHOT — chunked-bytea engine (1 MiB chunks,
  STORAGE EXTERNAL), advisory xact locks, PG staging + P1D TTL sweep,
  openChannel/ScratchBlob for JGit, BlobDiskIndex one-query, reference
  DDL for consumers (libs ship no migrations), zonky test infra.
- Queue after WP-LIB: WP-ARTIFACTS (branch: pom H2→PG, zonky, fresh PG
  V1 lineage incl. blob tables, serving call-sites/BlobSender, stateless
  Dockerfile, delete H2 lineage); WP-MIRROR (branch: lib bump, blob
  tables migration, drop blob dir + volume — cache re-fills, no data
  copy); WP-TOOL (migration/ module: schema|blobs|rows|verify, disk-walk
  driven); WP-GITHOST (later: lib bump + lineage + pack-blob copy).
- Before cutover (runbook §12, operator-gated): C3 backups + restore
  drill are still missing; freeze window; run-args edit (drop volume +
  H2 env for artifacts); release order lib → consumers.

### Lib calver campaign 2026-08-13 (in flight)

blobstore + registries joined the release train today, closing the
db-patience wave-2 remnant at the same time:

- **qits-blobstore 2026.813.161828 RELEASED** (first calver). Carries
  DbRetry on `ArtifactRepositoryService`: `require` via DbRetry.call,
  `ensure` converted @Transactional → DbRetry.inNewTx (body flushes).
  Recipes + `.qits-maven-settings.xml` modeled on eventstream; H2-only
  suite, so no `user: build` stanza. Both CI runs green, pom in the
  registry, tag + stamp synced to local main (08185aa).
- **qits-registries 2026.813.162639 RELEASED** (first calver). All five
  require*/resolve* seams on DbRetry.call (all pure reads; resolveForPull
  and resolveManifest wrapped whole across their two-row reads).
  qits-db-core declared per format module (npm/maven/oci — common has no
  DB code, npm skips common). Blobstore pinned to its calver, snapshots
  flag dropped from the qits-maven repo block. Four artifacts verified in
  the registry, tag + stamp synced home (604410f).
- **Consumer bumps RELEASED AND DEPLOYED**: mirror 2026.813.163303,
  githost 2026.813.164937, artifacts 2026.813.165241 — all three
  containers verified on their release shas, edge 200, stamps + tags
  synced to local mains. Not one `-SNAPSHOT` pin remains in a tracked
  pom anywhere. The db-patience wave-2 remnant (mirror-lib registry
  reads) is CLOSED — the seams are live in the deployed mirror.
- **SWARM LANDMINE FOUND AND FIXED: start-first deadlocks host-port
  services.** Mirror's deploy (the first host-port rolling update since
  the cutover) sat Pending on "no suitable node" — the old task holds
  the host port, start-first never stops it. Salvage: `docker service
  update --update-order stop-first <svc>`. Durable fix: `update_order:
  stop-first` in deployments.yml (a shipped parser key; the deployer
  already used it for itself) committed to ALL FIVE host-port repos —
  mirror/githost/artifacts (released, proven live: both later deploys
  cut over stop-first with no salvage) and dns/edge (on local mains,
  rides their next release).
- Release-endpoint detail learned: `summary` max 100 chars (400 otherwise).
- Residue: qits-artifacts `docs/openapi.yml` regenerates on verify and
  carries pre-existing version drift (uncommitted, untouched).
- Fleet calver audit (42 submodules): everything has a cycle EXCEPT
  qits-spa-docs (no recipes, 0.0.0), qits-repositories (empty stub),
  cli-bootstrap (deliberately off-train), and two wired-but-never-released
  SPAs (spa-githost, platform-spa-mirror). qits-ci-daemon has a cycle but
  its 2026.803.184200 tag was never synced home.

## Backlog

### Top

- **Volumes-kept re-bootstrap row hole.** Kept ACTIVE deployment rows +
  unwrapped services + unchanged mains → tip-ordering drops the replays and an
  app can stay seed-served. Salvage and full detail in the swarm-migration
  memory.
- **GitHub backup sweep.** Most submodule mains and their tags exist only
  locally and on the platform githost (measured 2026-08-12: 31 submodules,
  ~213 local-only commits, plus everything since). `git fetch --tags` from the
  platform githost FIRST, then push mains + tags to GitHub — release stamps
  live only on the githost until pulled.
- **Repository backup rows sit at AUTH_REQUIRED** — nobody has signed in to the
  backup remote since the volume wipes. The sign-in terminal is on the project
  setup page. (verify still open)

### qits-containers

- Proxy adoption (the data plane ships flag-off; per-tunnel-secret contract).
- First real workspace/agent smoke through the orchestrator.

### Repos, pipelines, host steps

- **Host step, byte-plane split:** dockerd `registry-mirrors` →
  `localhost:8082` (awaiting user decision).
- **qits-projects has no `ci-event-upstream-eventstream.yml`** (verified still
  missing) — the train never bumps its eventstream pin, so it is bumped by
  hand. Add the recipe.
- **qits-spa-docs has no CI recipes** (version 0.0.0, off every train).
- **qits-repositories** is an empty stub — remove it.
- **Drop projects' archunit workaround** (`epics/src/test/resources/
  archunit.properties`) — the `allowEmptyShould` fix is released and pinned.
- **Release pipelines push `:$QITS_CI_SHA`, not `:$version`.** Fixed in the ten
  stage-B repos of 2026-08-12; whether the rest still carry the wart is
  unverified. (verify still open)
- **qits-deployments' stale microprofile `git-host-url` default** — rides its
  next release. (verify still open)
- **cli-bootstrap: a failed clone refresh must fail LOUD** — stale clones with
  dead origins built old sources silently until version pins caught it.
- **cli-bootstrap TUI has never run under a real TTY** — only `PlainUi` is
  proven. (verify still open)

### Service and code defects

- **Seed CI's agroal pool never self-heals after a postgres gap** — the seed
  keeps a dead pool where the deployed services now hold through the outage.
- **AgentTunnelProxyTest holds an untimed `HttpClient.send`** — can wedge
  `verify` forever.
- **qits-events' release yml still carries the `rmi` wart** — fixed at source
  (`7b23dba`), rides its next release.
- **qits-eventstream first-boot watermark race** — startup sweep and scheduler
  both insert the initial watermark; the loser WARNs a
  `consumer_watermark_pkey` violation. Make the init insert idempotent.
- **qits-workspace-daemon surefire flake** — failed once on a rebuild of a tree
  that had built green, unreproduced.
- **`vertx-http-proxy` breaks on h2c inbound** (edge and the workspaces proxy
  family).
- **qits-workspaces CaptureService mints `feature/<timestamp>` branches** that
  collide directory-wise with the `feature/<epic>/<feature>` convention — needs
  its own prefix.
- **`ResolveConflictService` is carried nowhere** — reassigned to workspaces in
  migration-plan.md §9 item 11, never moved.
- **Epics MCP:** `AgentLaunchService:604` passes the repo NAME into the MCP
  `repositoryId` param while `RepositoryMcpTools:76` filters by id; and
  `ScopedMcp.allowedTools` is inert on the Claude path but filters on Kimi ACP
  chat. (verify still open)
- **qits-projects agent containers have no re-provision path** — the daemon
  latches `provisionStarted` for the process lifetime and `ensure` no-ops on a
  running container, so recovery is remove-the-container-and-re-ensure.
  (verify still open)
- **`target` vs `deploymentTarget` wire spelling** is inconsistent.
- **Spec-aware release promotion** — one release still pushes several refs;
  quiet pushes cover part of it. (verify still open)
- **The legacy-network enforcement flip**
  (`qits.platform.deployments.legacy-network=` empty) and the cross-app URL
  migration it needs. (verify still open)

### Docs and prose

- **Lib README's stale PatientPgDriver native watch item** — native is proven
  live; drop on next touch.
- **11 comment references to the removed `db-patience-plan.md`** across
  githost/ci/workspaces/projects/integrations-quarkus — re-point them to
  `docs/project-setup-quinoa-angular.md` on the next touch of each repo.
- **qits-ci's image-pull/health-gate prose still names qits-cd** (the facts
  hold).
- **qits-spa-artifacts' cleanup-page banner** says "live pins from qits-cd and
  qits-ci" — fold into that repo's next release, not a cascade of its own.

### UI

- **prompt-attachments has no SPA client** in either SPA — the backend and SSE
  topic exist, paste/sketch delivery is unwired.
- **`ui/async.ts` copies have drifted** between the SPAs.
- **Deployments UI joins `environment.name === project.slug`**, so project
  `qits` draws as "no environment" and env `dev` lands in the unmatched bucket.
  Stale convention. (verify still open)
- **The projects SPA does not render `failureDetail`** on the agent-container
  read (additive backend field). (verify still open)
- **Compare/commits view** to replace the muted placeholders on the epic tree;
  epic-level implemented state for zero-feature epics (Epic has no implemented
  field, so those can only show "open").

### Store and GC

- **First real GC sweep** has never run — currently a proven no-op. When the
  store ages past P30D, follow the README's first-sweep choreography (dry-run
  review → backup + blob listing → sweep → verify store-summary balance).
  Nothing sweeps without the review.
- **SHUTDOWN COMPACT maintenance restart** is the only way packument CLOB space
  comes back after proxy evictions — documented in the artifacts README, never
  run by code.
- **ci-screenshots / ci-videos GC**: excluded by configuration today; the user
  wants an own-like "$last versions" strategy eventually.
- **Git pack GC** (old BD): separate, DFS-gated, untouched by the GC reshape.

### Deferred designs (each has its doc in the repo root)

- `qits-artifacts-postgresql-plan.md` — artifacts off H2 onto PostgreSQL.
  Unstarted; start at its work-package table.
- `qits-idp-plan.md` — phases 2/3, the user-auth track (gateway pointing at idp
  for humans). Machine auth is live platform-wide.
- `eventstream-causation-split-plan.md` — split qits-causation out of the
  eventstream jar so entity modules stop inheriting an HTTP server, a
  persistence unit and darkness keys. Carries the per-repo removal inventory.
- `workspace-overview-ux.md` — the workspace overview redesign; the real model
  is project → epic → workspace views.
- `gateway-route-events-plan.md` — schedulable now (see the audit entry above).
- Not planned, user decision 2026-08-05: telemetry for workspace-launched dev
  services (LD-b). Console capture is the answer for both daemons.

### Parked: userflows

First real usage of `libs/qits-userflows` (Playwright user-story framework:
@UserStory/@UserflowPrecondition/@UserflowRunsAfter, topological orderer,
UserflowContext, report emission), plus the doctrine in its package-info.

- **Execution profiles**, two axes: environment kind (mocked, or a live scope —
  `dev`, later preprod/prod, plus the PLATFORM scope) and vantage (in-network |
  external). A profile is a small properties file (`qits.userflows.profile`);
  one gateway base URL covers UI + API. Profiles should eventually DERIVE from
  qits-deployments' registry instead of being hand-written.
- **Capabilities**: a marker interface (e.g. RepositoryExists) accepted by
  @UserflowPrecondition; providers are stories annotated @UserflowProvides plus
  an environments gate — mocked provider stubs, live provider IS the real
  create-flow. Zero or two active providers is a hard error.
- Phasing: framework profiles+gating+doctext → capabilities → first consumer in
  qits-ci (mocked, against the packaged app + StubGitHost) → live-external →
  live in-network (CI pipeline; the step env needs a gateway URL) → publish
  reports to the ci-screenshots/ci-videos artifact types.
- Open questions: where the cross-service suite lives long-term; packaged vs
  dev-mode boot for mocked runs; the surefire/failsafe chain constraint; auth
  for live profiles (idp machine tokens); report identity per profile.

## Awaiting a user verdict

- **WO-b**: the merge panel left the workspaces overview (merging lives on the
  detail route). Keep it that way, or bring a merge entry point back?

## Preserve

- Root untracked user files: `daemon-artifact-identity-plan.md`,
  `workspace-overview-ux.md`.
- `services/qits-workspaces/.claude/` is user-owned and untracked.
- Do not reintroduce EventStream as a CI/Workspaces submodule or reactor module.
