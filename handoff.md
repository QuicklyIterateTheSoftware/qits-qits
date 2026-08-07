# Handoff

Updated 2026-08-06 (late). Everything shipped-and-verified has been removed; history is
in git. What remains is open, pending, or standing. This is the ONE handoff document —
handover.md (the userflow plan) is folded in below and deleted.

## In flight right now

- **The shell bootstrap is retired** (2026-08-07): `qits-local-up.sh` is now a shim that
  compiles `cli/qits-cli-bootstrap` and runs it, passing modes, flags and every `QITS_*`
  variable through. It pins the wrapper directory, the clones and the log, so the run no
  longer depends on where you stand, and recompiles only when the sources are newer than
  the binary (`QITS_CLI_BUILD=always|never` overrides). The 1298-line POSIX port is in git
  history; its operational comments live in the CLI's sources, which is now the only place
  they exist. The CLI's AGENTS.md and README no longer claim the CLI is unproven — that
  claim was already false when the v3 cutover shipped. `local-platform.md` gained the new
  invocation and a header warning that the rest of it predates the v3 merge-back.
  **Proved by two full `unwrap` + `bootstrap` cycles**, and each found a real bug:
  - A **stale CI row failed a phase in zero seconds**. On a rerun nothing is pushed, so no
    new run exists, and the CLI read the newest run at that sha as this phase's outcome.
    qits-workspaces carries four runs at one commit from the release train, two red and two
    green, newest red — so the phase died while the deployment it had just asked for went on
    to land. The deployment-row side of that wait already had a baseline id; the CI-run side
    now has the same one. A stale GREEN row still counts on purpose: it means no new run is
    coming, which is what the lost-event replay acts on.
  - The CLI **falls back to `bootstrap` only when given no arguments at all**, so a leading
    flag was an unknown top-level option and `./qits-local-up.sh --skip-build` would have
    failed. The shim names the mode when the first argument is a flag; `--help` and
    `--version` still reach the top level.

  The second cycle finished clean in 3m44s: 43 phases of 45 (2 skipped as already
  published), no phase warnings, all ten applications healthy, every gateway route 200,
  and `/workspaces/` verified in a browser (real data, no console errors). A warm cycle is
  that cheap because `unwrap` removes the seed images but not docker's build cache, and the
  volumes keep the registry blobs — so the deployables are pulled, not rebuilt.
- **v3 IS LIVE AND FULLY WIRED**: qits-platform-deployments (the cd+serviceregistry
  merge-back) runs the platform — 7 platform services from `platform/main`, 3 dev
  services from `environment/dev`, deployed by the native CLI (15 proving-run fixes,
  green cold bootstrap 22m29s, warm cycle: unwrap 11s + bootstrap 3m29s). The browser
  view (`:8480`, `0.0.0.0` default for WSL2) is proven live. The gateway serves the
  real home SPA; `/platform-deployments/` serves the relocated deployments UI.
- **The release train ran END TO END and COMPLETED** (2026-08-06 evening): the
  ui-components release (`2026.806.184725`, the Deployments nav entry) cascaded through
  all seven SPA releases and the full service tier; every sidebar now links
  `Deployments -> /platform-deployments/`. All ten containers healthy on the released
  builds; ALL release commits are synced into the checkouts and GitHub; zero unpushed
  commits anywhere. Cascade frictions handled: three twin-build image races replayed
  (the -o qits.no-ci discipline matters), one orphaned step-container name collision
  cleared, two SPA specs pinning the old nav fixed and released, the retired qits-cd's
  event triggers stripped (its resurrection was blocked by a failed env-branch build;
  triggers are gone now). Cosmetic leftovers: a handful of red quiet-ref runs, and the
  imageless release-train repos auto-registered in the services listing (amendment-7
  consequence, harmless).
- **GC pins retargeted** (2026-08-07, qits-artifacts `9779c38`): the pin source was still
  `http://qits-cd:8080/cd/api/pins`, which resolves nowhere since the merge-back — so every
  plan and every sweep aborted fail-closed and the cleanup page showed the outage. It reads
  `http://qits-platform-deployments:8080/platform-deployments/api/pins` now, the same
  `{"pins":[{"applicationName","shas"}]}` shape from `RollbackPins`. The report's source
  name, its outcome sentences and the keep reason name the deployer too. **The `cd-` config
  keys deliberately keep their names** — renaming one loses a deployment's override in
  silence, and nothing sets them. Found along the way and fixed: the native
  `PackagedProcessIT` was already red before this change, expecting an aborted sweep to
  report an untouchable pool it never measured.
  Still stale, cosmetic, not shipped: `qits-spa-artifacts`' cleanup-page banner prose says
  "live pins from qits-cd and qits-ci". It only renders when the pins fail, which this fix
  stops, and moving it costs a SPA release plus a webui bump — worth folding into the next
  qits-spa-artifacts release rather than a cascade of its own.
- **Open follow-ups**: qits-ci's image-pull/health-gate prose still names qits-cd (facts
  hold); `target` vs `deploymentTarget` wire spelling; buildkit migration for the
  remaining SPA-service pipelines (`--network qits-net` relies on the legacy builder);
  spec-aware release promotion (today both deploy branches push, double/triple builds);
  the enforcement flip (`qits.platform.deployments.legacy-network=` empty) + the
  cross-app URL migration it needs; two cosmetic red runs on qits-spa-cd/home mains
  (interim spec commits, superseded by their releases).
- **Known first-run debts fixed tonight in the CLI**: stale ACTIVE rows without
  containers, tab-eating output sanitizer vs the container check, write-shaped
  auth-plane probes, pinned-only seed publishes (version immutability!), bearer on the
  deployer's guarded environment writes.

## Parked workstream: userflows (folded from handover.md)

First real usage of `libs/qits-userflows` (the Playwright user-story framework:
@UserStory/@UserflowPrecondition/@UserflowRunsAfter, topological orderer,
UserflowContext, report emission) + writing the doctrine into the module's doctext
(package-info). The design, adjusted to v3:

- **Execution profiles**, two axes: environment kind (mocked | a live scope — `dev`,
  later `preprod`/`prod`, plus the PLATFORM scope) and vantage (in-network | external).
  A profile = a small properties file (`qits.userflows.profile`); one gateway base URL
  covers UI + API. Profiles should eventually DERIVE from qits-platform-deployments'
  registry instead of being hand-written.
- **Capabilities**: a plain marker interface (e.g. RepositoryExists) accepted by
  @UserflowPrecondition; providers are stories annotated @UserflowProvides + an
  environments gate — mocked provider stubs, live provider IS the real create-flow.
  Resolution over the classes in the run; zero/two active providers = hard error.
- Phasing: framework profiles+gating+doctext -> capabilities -> first consumer in
  qits-ci (mocked profile against the packaged app + StubGitHost) -> live-external ->
  live in-network (CI pipeline; step env needs a gateway URL) -> publish reports to the
  pre-seeded ci-screenshots/ci-videos artifact types.
- Open questions that remain: where the cross-service suite lives long-term; packaged
  vs dev-mode boot for mocked runs; surefire/failsafe chain constraint; auth for live
  profiles (idp machine tokens); report identity per profile.
- Stale note fixed on pickup: UserflowTarget's javadoc references -Pextended, which no
  longer exists (the `extended` JUnit tag + -DskipITs=false is the convention).

## Awaiting user verdicts

1. **WO-b judgment call**: the merge panel left the workspaces overview (merging lives
   on the detail route). Keep it that way, or bring a merge entry point back.

Resolved 2026-08-06: the **git-storage flip executed, and the file backend retired
the same day** (user: "the disk storage should be gone"). All 41 repositories imported
and three-check-verified; every path proven live: protection + both bypasses,
post-receive → CI, repository create/import over HTTP, history reads, the full release
train (SCMRelease → event run → SoftwareRelease), workspace container provisioning, a
service deploy, and qits-artifacts redeploying itself from its own DFS store — twice,
the second time as the dfs-only binary (`508e598`). The `qits-repositories` volume is
deleted (tarball: `~/qits-git-bares-final-2026-08-06.tar.gz`), the file-backend code
is gone, and `qits-local-up.sh` seeds over the wire (home `6843faf`). Full record at
the top of git-host-storage-unification-plan.md.

Resolved 2026-08-06: the rewritten **`qits-local-up.sh` is proven end to end** — a full
cold bootstrap ran green in an isolated docker-in-docker daemon: seed stack, wire
repository creation, release replays, then all ten applications built and deployed
through the platform's own pipeline, qits-cd's self-update handoff included, gateway
healthy and the DFS git host serving clones. Five attempts; each earlier failure was a
real cold-start bug, all fixed: the `${user.home}` heredoc bashism (`b03bce2`); no
released artifacts on a fresh platform — bootstrap now replays the four publishers'
release pipelines (`3a19ed0`, `97bda56`); H2's compiled-check defect killing every run
after pool idle — V5 had dropped constraint names V1 never created; fixed for real
with a Java migration (qits-ci `4439c4b`, deployed live); stale webui gitlinks in
qits-ci/qits-cd pinning pre-CalVer `@qits/ui-components@0.0.4` (`b698b99`, `8ef8a8f`,
deployed live; qits-spa-ci's main had also never been pushed to the platform host);
and a lost fire-and-forget build-succeeded event — the deploy wait now replays it once
when a run is green with no deployment row (`97bda56`). Then the REAL platform was
torn down (containers, all volumes including the DFS store, network, every seed and
build image, the musl toolchain) and cold-bootstrapped from source on the host daemon:
green in ~22 minutes (docker layer cache carried unchanged sources), all ten
applications healthy, 32 repos on the fresh DFS host, blob API and clones serving, no
bares volume. The skip-build caveat is gone — both paths are proven. NOTE the reset:
run/deployment/event history restarted, throwaway probe repos (drift-forge, sv-train,
the UUID imports) are gone, idp client secrets were kept (.qits-bootstrap.env). This
unblocks the env re-model rollout (user's runbook).

Resolved 2026-08-06: the git host gained **content-read endpoints** (user's ask) —
`GET /artifacts/git/{repoId}/blob/{rev}/{path}` (raw bytes) and `…/tree/{rev}[/{path}]`
(JSON listing), `{rev}` a branch/tag or full sha, resolved sha in the `Git-Commit-Sha`
header, unauthenticated like the rest of the host (qits-artifacts `3f8ca71`). qits-ci
consumed them (`1d01e2b`): the bare-mirror cache, fetch/retry machinery, the CONTENDED
requeue path, and the git binary itself left the image — config is read at the exact
event sha over HTTP. Both deployed and proven live (a drift-forge push ran green with
no other config path in existence). Natural follow-up, not done: qits-projects'
`GitSubmoduleParser` (`git show <rev>:.gitmodules` in its mirror) is the second
consumer of the same verb. qits-workspaces' mirror cache **stays** — merges and
preflights are computations the wire cannot express, not file reads.

Resolved 2026-08-06: the explorer copy (old item 1) shipped — lede approved as-is, the
count punctuated, excluded rows say "not collected" (qits-spa-artifacts `85ea629`,
live via the qits-artifacts webui bump `a72cfd7`, verified in the browser). Note the
shape of that release: a green qits-spa-* run ships nothing by itself — the SPA goes
live only when qits-artifacts bumps its `service/src/main/webui` submodule and
redeploys, queue empty first (self-hosting landmine).

## Open work, not user-gated

- **First real GC sweep**: currently a proven no-op (2-day-old platform, everything
  inside the windows). When the store ages past P30D, run the README's first-sweep
  choreography (review the per-repo or global dry-run → H2 backup + blob listing →
  sweep → verify store-summary balance, cd restart pulls, evicted proxy package
  re-caches). Nothing sweeps without the review.
- **SHUTDOWN COMPACT** maintenance restart: the only way packument CLOB space comes
  back after proxy evictions; documented in qits-artifacts README, never run by code.
- **ci-screenshots / ci-videos GC**: excluded by configuration today; the user wants an
  own-like "$last versions" strategy for them eventually (out of scope for now).
- **Log-streaming leftovers**: none since 2026-08-05 — qits-events gained its OpenAPI
  export test (every repo has one now). Standing note: qits-artifacts publishes
  `paths: {}` (raw-route service — fine, known).

## Longer-term backlog (from settled plans)

- **Workspace views**: the pre-PoC overview tree shipped; the real model is
  project → epic → workspace views (user's mental model, recorded 2026-08-04) — future
  design work.
- **qits-idp**: machine auth is live platform-wide; the user-auth track of
  qits-idp-plan.md (gateway pointing at idp for humans) remains.
- **Workspace-launched dev services telemetry (LD-b): NOT PLANNED** (user decision
  2026-08-05). Console capture is the answer for both daemons; qits-observability's
  README "missing sender" note is a description, not a TODO.
- **Durable log retention (LG): SETTLED** (user decision 2026-08-05). qits adds no
  external component that cannot be embedded into the Quarkus app — no third-party log
  backend, no sidecar collector. The bounded live window stands; if it ever proves
  insufficient, the only path is a qits-owned persistent store inside
  qits-observability.
- **Git pack GC** (old BD): separate, DFS-gated, untouched by the GC reshape.

## Standing facts and landmines (not in memory files)

- **Release a self-hosting repo only after its epic build drained the queue** — a
  release run's npm install can race the redeploy of the service building it.
- Security model: publish surfaces are tokenless on qits-net by decision; qits-idp
  gates them together when its user track lands. `DaemonOpenPublishTest` and siblings
  pin this — re-gating one surface alone fails the build.
- idp token endpoint is not reachable via gateway; call it on `qits-net`. Machine auth
  is ON live (`QITS_AUTH_MACHINE_REQUIRED=true`); only the `qits-artifacts` idp client
  carries `project=*` (see memory: machine-token-minting).
- Git storage: DFS-only since 2026-08-06 — packs, indexes and reftables are blobs in
  qits-artifacts' own store, cataloged in H2 (`git_pack`/`git_pack_file`); there is no
  file backend, no storage config property, and no `qits-repositories` volume anymore.
  Rollback is roll-forward: every prior image sha serves the same DFS store.
  **Never run `DfsGarbageCollector`**: in a store without deletes it doubles the
  footprint (plan §1.7; posture ⚖2(b) — no git GC, in writing). The git CLI cannot
  open a DFS repo — every operation is the wire protocol; receive-pack is the sole
  writer of everything. `DfsBlockCache` rides its 32 MiB default, which today's whole
  git host fits inside. The rewritten `qits-local-up.sh` wire-seeding flow has not yet
  run a fresh bootstrap end to end — watch the first one.
- musl builder supply-chain flag stands: `FROM localhost:8081/...` + toolchain fetched
  from `more.musl.cc` per build.
- qits-ci: a record targeted by a MapStruct mapper needs `clean` after changing (stale
  generated impl → `NoSuchMethodError`); same family as stale `target/` after source
  deletions. qits-cd joined the family 2026-08-06: after a method-signature change,
  plain `verify` ran callers against the stale class (32 false 500s) — use
  `clean verify` after signature changes.
- GC operational shape: per-repository plan/sweep are subresources under
  `/artifacts/api/gc/repositories/`; pins are fetched per run from qits-cd
  `/cd/api/pins` and qits-ci `/ci/api/daemon`, any failure aborts the whole run; blob
  bytes lag identity deletion by up to two runs (row-less + 7-day grace); Σ(per-repo
  reclaim) ≤ global by design.
- Log export: all eleven services (idp included) carry the explicit
  `quarkus.otel.logs.*` block + an `OtelLogConfigTest` drift guard; the behavioral
  proof lives once, in qits-events (`OtelLogBridgeTest`/`PackagedLogBridgeIT`).
  Resource identity (`service.version` = deploy sha) is injected by qits-cd at
  `docker run`; a service shows it after its first post-2026-08-05 deploy.

## Preserve

- Root untracked user files: `daemon-artifact-identity-plan.md`,
  `workspace-overview-ux.md`.
- `services/qits-workspaces/.claude/` is user-owned and untracked.
- Do not reintroduce EventStream as a CI/Workspaces submodule or reactor module.
- QuarkusTest on this host: pass `-Dquarkus.http.test-port=0` (8081 is the npm
  registry).
- Moving the daemon pin stays a human act: edit cd run-args volume + compose, restart
  qits-cd, then redeploy qits-ci — in that order (qits-cd caches run-args at boot).
