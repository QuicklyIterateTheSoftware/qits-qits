# Handoff: ship the ci-daemon (daemon artifact identity)

Updated 2026-08-03. Prior contents (cold bootstrap, OCI integration, serial release-train E2E)
are proven and settled on the local env; they were removed. History is in git.

## Objective

Implement `daemon-artifact-identity-plan.md`: give the ci-daemon binary an identity in
qits-artifacts, publish it from a real release pipeline, and keep qits-ci consuming it by digest.
Done when a release of `daemons/qits-ci-daemon` publishes through the train to qits-artifacts and
qits-ci launches step containers from that published artifact.

## Decisions

All five ⚖ recommendations from the plan are adopted (user said "start implementing it"; flag
before BL lands if any should flip):

- ⚖1 type name: `daemon-binaries` (enum `DAEMON_BINARIES`)
- ⚖2 `qits.ci.daemon-version` keeps pinning the digest
- ⚖3 pin surface: new `GET /ci/api/daemon`; AZ allowlist only as transition belt
- ⚖4 daemon publish joins the release train (BL)
- ⚖5 adopted orphan rows use version = digest hex

## Workstreams

- **BH** — `daemon-binaries` type in qits-artifacts: V6 migration, `RepositoryType`, seeder row,
  `PUT/GET /artifacts/daemons/<name>/<version>`, own body limit, token-filter guard, census.
- **BI** — adopt the three orphan blobs (ops; needs BH deployed to the live platform). Proof:
  `orphanBytes = 0`. Gates every sweep.
- **BJ** — qits-ci: `GET /ci/api/daemon` + boot-time digest shape check.
- **BK** — daemon GC strategy. Deferred: gated on the GC substrate (AZ/BA) from
  artifacts-gc-plan.md.
- **BL** — release-train publish: seed `qits-ci-daemon` on the platform git host, two pipeline
  files in the daemon repo, `CiArtifact.Type.DAEMON`, bootstrap upload switched to the new PUT.

## In flight right now

- Nothing running. **BOTH ROLLOUTS COMPLETE.** Auto-adoption proven live 2026-08-03 18:11:
  daemon release `2026.803.181013` → SoftwareRelease `ae971627` → listener adopted → probe
  PROVEN in 318ms → `/ci/api/daemon` flipped to `{"daemonVersion":"2026.803.181013",
  "source":"adopted"}` with no config touched → smoke run `8a44a0fe` recorded the adopted
  version. Deployed: qits-ci `f5cf0fc7` (2026.803.180357, probe Hello latch), daemon flake
  fix released first-try green. Platform 10/10, queue drained.
  Loose end (non-blocking): `previousDaemonVersion` blank until the next release (the two
  non-PROVEN rows are skipped, by design).
- Nothing running. **AUTO-ADOPT FULLY PROVEN 2026-08-03 19:22.** qits-ci `2026.803.191734`
  (`9fa5f27d`, carrying the 3-way probe + all fixes) re-probed the previously-UNKNOWN
  `2026.803.184200` through the full Hello→Ack→AckReceived exchange and adopted it:
  `/ci/api/daemon` = `{daemonVersion: 2026.803.184200, previousDaemonVersion:
  2026.803.181013, source: adopted}` — the fallback rung exists for the first time. Smoke
  run `ba690c69` stamped the new calver. Zero failed-Ack WARNs, zero name conflicts, zero
  periodic probe activity (read-only health checks confirmed), 10/10 healthy. The last
  manual pin move on this platform was 17:07Z. Four live-only defects found and fixed today:
  startup probe deadlock, Hello-vs-admission race, probe name collision, container-launching
  health checks.

## Carried from retired plan docs (docs deleted 2026-08-03 per user)

`ship-the-ci-daemon.md`, `daemon-artifact-identity-plan.md`,
`projects-volume-decoupling-plan.md`, `ci-daemon-autoadopt-plan.md` are deleted — their
substance shipped and is proven live. Residual items that survive them:

- **Restart-reconciliation IT is still missing** (ship-the-ci-daemon §2): qits-ci's boot
  sweep (`Removed N orphaned CI step containers` / interrupted-run FAILED marking) is
  human-verified only; an IT that kills the registry mid-step and restarts the observer
  would close it. Also noted there as unreachable: "a refused stale dial" (daemon
  self-terminates on socket loss).
- **OTLP exporter warns per export** against a possibly-absent qits-observability
  (ship-the-ci-daemon §3); `OTEL_SDK_DISABLED=true` is the escape hatch.
- **BI remnant**: one rowless daemon blob (old bootstrap digest publish `fbefa249…`) keeps
  `orphanBytes` non-zero on this platform; fresh bootstraps publish with identity now, so it
  never recurs. Adopt or ignore until GC work.
- **BK (daemon GC strategy)** stays deferred, gated on the artifacts GC substrate; the pin
  surface it needs (`GET /ci/api/daemon`, now with previousDaemonVersion) is live.
- **Three REJECTED ladder rows** (`2026.803.91607`, `2026.803.174754`) are terminal by
  design though both binaries were fine — defect-era verdicts, not bad releases.
- **Migration-rollback trap** recorded in memory: a qits-ci release carrying a Flyway
  migration has no cd rollback; roll forward with a kill-switch env instead.
  Still pending: GitHub pushes of all changed submodule mains + root gitlink commit (large
  backlog now: artifacts, ci, projects, events, workspaces, ci-daemon, root).

### Rollout 2 history (kept for reference)
- **Rollout 2 first attempt hit an outage; recovered.** qits-events `74b3cdf8`
  (2026.803.170350) deployed, `?attr` gate proven. Pin moved to calver. qits-ci release
  `0e09ca32` (2026.803.171135) FAILED to deploy: `DaemonReleaseListener.onStart` probes
  synchronously on the startup thread → probed daemon dials ws://qits-ci:8080 which is not
  bound yet → healthcheck kills the container. cd restored the pre-V8 predecessor, which
  crash-loops on Flyway validate (V8 applied, not resolved locally) — **cd restore is not a
  rollback across a migration** (memory + plan lesson). Proof 1 stands: the version-addressed
  template served the binary and it ran.
  - Track 1 DONE: platform 10/10 again. qits-ci `0e09ca32` deployed with
    `QITS_CI_DAEMON_AUTOADOPT_ENABLED=false` in run-args (backup
    `application.properties.bak-preautoadopt-off`). `/ci/api/daemon`: calver pin, source
    configured, readiness UP. Proof 1 DONE: run `3080f99d` green with
    `daemonVersion=2026.803.91607` via the flipped template. cd itself reaped the
    crash-looper; probe container was auto-reaped (evidence preserved in cmdlog).
  - Track 2 DONE: `6c906e5` (async startup reconcile) released as qits-ci
    `2026.803.173730`/`c2c5c57e` — boots in 0.150s with autoadopt ON. Kill switch removed.
  - Step 5 attempt: daemon released `2026.803.174754` (`89890402`), SoftwareRelease fired,
    listener adopted on the worker thread (656ms). **Second defect found: probe reads
    capability right after websocket ADMISSION, one round trip before the Hello frame —
    every candidate REJECTED as "capability null"** (registry's own "announced capability"
    log never appeared). Fail-closed held: pin stayed configured, 10/10 healthy.
  - Fix agents running (Sonnet, parallel): (1) qits-ci probe awaits a Hello latch, regression
    test forcing the admission→Hello gap; (2) daemons repo flaky
    `DaemonMainTest.anUndecodableFrame…` (cost one retry today).
  - Then: release fixed qits-ci (no migration → normal rollback), release the daemon flake
    fix as the THIRD daemon release = the adoption proof (the two non-PROVEN
    `ci_daemon_pin` rows from the fixed defects stay — newest-first walk out-ranks them;
    noted: fallback past the new release lands on configured, not on those).
  NOTE gateway is :8080; :8081 is the registry (earlier briefs had it swapped).
  NOTE any qits-ci release carrying a Flyway migration has no cd rollback from now on —
  roll-forward only (see memory).

## ROLLOUT 1 COMPLETE — decoupling proven live (2026-08-03)

- Deployed: qits-artifacts `cabf905a` (2026.803.160505), qits-projects `6835aa6e`
  (2026.803.165125) — **zero `qits-repositories` mounts**, mirrors under `/data/mirrors`,
  push token in env.
- All four §5 proofs PASS. Headline: pull advanced a protected default branch through the
  hook (token accepted) and produced the first pull-caused `ci_run` ever (`db52e8dd`).
  Default-branch delete still 400s and the hook log proves the delete path sends no token.
  `-o qits.no-ci` holds alongside the token. Platform 10/10 healthy.
- Mid-rollout regression found+fixed: projects pushed tokenless → hook refused silently.
  Fix `a801e7e` (token on 7 host-push sites, deleteBranch excluded, refusals 400+WARN);
  wiring `52dd7d8` in qits-local-up.sh + live run-args.
- Probe leftovers (inert, deletable): host repos `rollout-probe`/`drift-forge`, project
  `decoupling-probe` (`0d3fb314`, wrapper + two imports). Failed run `fb8d54da` was the
  agent's own timing artifact (branch deleted under a fresh run), not a defect.
- Pre-decoupling projects run-args backed up on qits-cd-config as
  `application.properties.bak-predecoupling`.
- BY offline done: qits-ci `7271737` (README boundary table + pin-ladder prose) + `decd36a`
  (orchestrator: restored `V2__daemon_runs.sql` bytes — the agent's comment edit would have
  failed Flyway checksum validation on every existing database; applied migrations keep their
  bytes). qits-ci-daemon `00fb069` (release pipeline no longer claims the pin is manual, drops
  the carry-the-digest echo). The agent also committed the user-preserved untracked
  `daemon-artifact-identity-plan.md` in root; orchestrator reset that commit — the file is
  untracked again, with its superseded-notes edits intact on disk.

## Pending live rollouts (both need user go)

1. **Decoupling** (projects-volume-decoupling-plan.md §7): deploy qits-artifacts (BM/BN,
   additive), then qits-projects; four proofs (pull creates ci_run, skeleton push visible,
   default-branch delete refused, projects green with no `qits-repositories` mount). Rollback
   after BT needs the mount line put back first.
2. **Auto-adopt** (ci-daemon-autoadopt-plan.md BY): deploy qits-events (BU), then qits-ci —
   template flip ships with the one final manual pin move to `2026.803.91607` (current digest
   pin 404s on the version route). Proof: one daemon release adopted with no human pin move;
   readiness stays UP; run rows show the calver.
- BW done: qits-ci `e1dbab4` — `CiDaemonContainerProbe` (mint → launch → await registration →
  read capability → reap; UNKNOWN under LaunchMode.TEST), `Launch` keeps `capabilityVersion`,
  probe image knob `qits.ci.daemon-probe-image=alpine:3`. Extended-tag IT beside the
  handshake IT.
- BX done: qits-ci `306f098` — `DaemonReleaseListener` adopts SoftwareRelease for
  qits-ci-daemon on a dedicated worker; startup seeds the ladder from
  `EventsDaemonReleaseLog.recentReleases(2)` (BU's `?attr` filter), oldest-first;
  `CiDaemonReadinessCheck` DOWN when source is NONE, reports rejected versions. **Plan
  contradiction, verified by running it**: a typed `QitsEventListener<SoftwareRelease>` gets
  null `occurredAt` (CanonicalJson mix-in hides QitsEvent-declared methods; only
  BuildSuccessful renames its timestamp) — implemented as `QitsRawEventListener` with
  signature `"SoftwareRelease"`, reading id/occurredAt off the envelope. Readiness path is
  `/ci/q/health/ready`. Verify green (90 service tests).
- BV done: qits-ci `21c0a38` — `V8__daemon_pins.sql` ladder (`ci_daemon_pin`, unique version,
  verdict check constraint), `CiDaemonPins` (lazy probe of UNPROVEN, configured pin as
  undemotable bottom rung), ports `DaemonProbe`/`DaemonReleaseLog`, `requireDaemonVersion`
  shape check at adoption (old boot check deleted), template default now version-addressed,
  `qits.ci.daemon-autoadopt-enabled` (off in %dev/%test), `/ci/api/daemon` extended. Verify
  green (ci 190, service 89).
- BU done: qits-events `482be0c` — repeatable `?attr=k=v` on the event list route, AND
  semantics, cap 8, exact fragment match incl. closing quote (`dae` does not match `daemon`).
  Verify green (events 36, service 61).

## Auto-adopt plan: written, decisions adopted

`ci-daemon-autoadopt-plan.md` (untracked, root). USER REVERSED "pin moves are manual"; USER
SETTLED version-addressed pinning (no digest resolution — version is the coordinate).
⚖6 adopted: "actually fail" = readiness DOWN + blank pin + runs failing (cd's health gate then
rolls back a bad deploy); refusing to boot rejected. ⚖7 adopted: `QITS_CI_DAEMON_VERSION`
stays as bottom rung/cold-start seed (bootstrap PUTs but emits no event).

Planner findings:
- qits-cd consumes NO bus events (trigger is qits-ci's direct POST). The listener idiom lives
  in qits-ci (`CiEventTriggerListener`); cd contributes the posture: gate, restore
  predecessor, no retry.
- A capability-mismatched daemon registers fine and dies later (`CiDaemonRegistry` acks
  mismatches) — "started" must mean registered AND capability-matched.
- Live landmine: current pin `ebc8fcc5…` 404s on the version route (bootstrap's row absent on
  this platform). Template flip must ship with one final manual pin move to `2026.803.91607`.
- `ci_run.daemon_version` fits calver, no migration; `/ci/api/daemon` gains `daemonName`,
  `previousDaemonVersion`, `source`.
- Decoupling rollout still pending (user-approved step; §5's four live proofs; artifacts
  first, then projects; post-BT rollback needs the mount line put back first).
- Native gates GREEN, both repos:
  - artifacts: `fd7f0ab` fixed the stale 7→8 type assertion in `PackagedProcessIT`
    (daemon-binaries only visible under `-Dnative`); `-Dnative` verify BUILD SUCCESS, 23 ITs.
  - projects: `09986f9` adds `GitHostFixture` (local bare over HTTP for the packaged binary);
    `-Dnative` verify BUILD SUCCESS, `PackagedSurfaceIT` 5/5, 119 service tests.
- Lesson recorded in memory: subagents' background builds die when their turn ends; run long
  builds from the orchestrator session.
- BT commits done: root `cd53420` (mount + env dropped from projects run-args), projects
  `9142cd3` (Dockerfile: no `QITS_REPOSITORIES_DATA_DIR`, no mkdir), artifacts `1aa89f7` +
  workspaces `6c8f3ab` (contract comments → two-way). BT agent got orphaned on background
  builds; orchestrator took over verification. `ForeignPtyTest` verify failure was load flake
  (10s deadline; passes in 0.094s idle) — never run the two native gates in parallel.
- Live rollout stays a separate user-approved step (§5's four live proofs).
- BS done: qits-projects `3c92cc4`. Pull/push/divergence on the mirror: refresh-then-write,
  every ref advance is a push to the host; park branch via delete-then-recreate (gitmirror has
  no force flag by design); `deleteBranch` maps hook refusal to 400. Exit test proven:
  `qits.repositories.data-dir` absent from src/main. Reactor green. Note: after a diverged
  push, the host briefly trails the forge until the next pull — deliberate, commented.
- BR done: qits-projects `107270a`. Reads on the mirror (`requireMirror`: clone-on-first-use,
  404/500 split), Path leaks removed from `WorkspaceLookup`/`PushSpec`. Two pulled-forward
  fixes: pull/push kept on `requireExistingOrigin` (no refresh — forced refresh clobbers
  reconcile state, would have broken production too); `deleteBranch` now pushes the deletion.
  `QitsConfigParser.readConfig` has no callers — nothing to migrate. Reactor green.
- BQ done: qits-projects `3770981`. Creation/lifecycle on mirror + ports; sidecar classes
  deleted. §7 live check: all 33 repos' sidecars matched their rows — nothing lost. Full
  reactor green (170 domain + 119 service). Extras: fixed a real CDI-proxy field-read bug in
  `GitIdentity`; `originPath` redirected to mirror `gitDir()` as stopgap for BR/BS; delete now
  removes the mirror cache (⚖2 text over §3.8 literal). Flag for BT: `PackagedSurfaceIT`
  project-creation needs a reachable qits-artifacts in a real launch.
- BP done: qits-projects `d5731ec`. Ports (`GitHostAddress`, `GitHostRepositories`,
  `GitMirrorRegistry`), HTTP impl in `wiring/` (instance HttpClient, Map bodies), config keys,
  `GitRemoteAuth implements GitCredentials`. Full reactor green (17+173+26+119). Note: BP added
  the missing `gitmirror` dependency to `domain/pom.xml`.
- BM+BN done: qits-artifacts `27b8d36` (lifecycle routes `PUT/GET/HEAD /artifacts/git/:repoId`,
  own 4 KiB BodyHandler, 9 suite cases on both backends) + `e81e083` (`qits.no-ci` skips the
  CI notifier; documented as a non-bypass in `ProtectedRefHook`). 473 tests green (was 452).
  Not run: `PackagedProcessIT` (needs `-Dnative`) — run it before deploying artifacts.
- BO done: qits-projects `578fd69`, `gitmirror` module, 17 tests green, reactor validates.
  Deviations (deliberate, supersede plan text): credentials as method parameter, not
  constructor; `initEmpty(defaultBranch)` folds init+HEAD into one call; `AheadBehind` kept.
- Next waves: BP → BQ → BR → BS (sequential, all edit `RepositoryService.java`) → BT
  (deployment decoupling + proof). Deploy artifacts after BM/BN (additive, safe); deploy
  projects only after BT.
- Still pending separately: GitHub pushes of the daemon-publishing submodule mains + root
  gitlink commit.

## Decoupling plan: written, decisions adopted

Plan: `projects-volume-decoupling-plan.md` (untracked, root). ⚖ decisions adopted as
recommended: ⚖1 lifecycle routes tokenless on `/artifacts/git` (no piecemeal gating);
⚖2 no delete verb on the host (defuses the project-delete blast radius, matches "we do not GC
git"); ⚖3 `qits.no-ci` ungated (doubles as AY's import verb).

Planner's ground-truth corrections worth keeping:
- workspaces moved sidecars to its own data dir as JSON, NOT into H2 — so the shared volume
  stays mounted on workspaces; this plan removes only projects' mount.
- `WorkspaceLookup` has no implementation anywhere — two whole call paths are dead code.
- projects' metadata sidecar duplicates two DB columns; `MetadataService` +
  `RepositoryDiscoveryService` get deleted, nothing migrated. One live-platform reconciliation
  check runs as a BQ pre-step (§7).
- Behaviour changes named in plan §4: skeleton commits fire post-receive (discarded — template
  ships no pipeline config), pulls advancing main now fire real CI, park-branch force-push
  fires CI, default-branch delete now refused by the hook, adoption becomes a wire question,
  mirrors add ~21 MB deletable cache.

## Git-storage flip: scoping verdict (2026-08-03, read-only)

**NO-GO for "flip default + wipe volumes + cold bootstrap".** It dies at the first deployable
push (`qits-local-up.sh:949`): nothing ever creates repos in the DFS catalog, so every push
404s — the experiment proves nothing about DFS because nothing DFS-shaped runs. It is also
exactly the sequence the unification plan names "the one to refuse" (DFS first, couplings
after, plan line 370), plus deleting bares which §5.4 forbids. Next failure points if patched:
frontend submodule clones 404 in every deployable's CI run; then the pipeline storm (push-based
pre-seed would fire 14 post-receive builds — no suppression push-option exists;
`CiPostReceiveNotifier` fires unconditionally).

Key correction: the plan is stale in the good direction. Precondition 2 is ~half done and the
harder half shipped: **qits-workspaces is at zero volume call sites** (the `gitmirror/` module
— clone/fetch/ls-remote/push only — is the reference implementation). **qits-projects is
untouched: 78 call sites** (46 git CLI via cwd-on-origin `GitExecutor`, 32 nio; silent
failers: `hasExistingOrigin`, `RepositoryDiscoveryService`; `Path` leaks in `WorkspaceLookup`
and `PushSpec`). Bootstrap has two volume writes (`:853` bare init ×25, `:864` bundle pre-seed
×15). No create/delete/import HTTP verbs exist on the git host (`GitRepositoryProvider.create`
has no route).

Proposed order: **AZ** (git-host lifecycle routes: create/delete/list/set-HEAD + bundle-import
that fires no post-receive — small, the true unblocker) → **AT-projects** (port gitmirror
pattern, the big one) → **AX-remainder** (DFS profile on `PackagedProcessIT` — the plan's own
definition of done) → **AY** (importer + bootstrap rewrite onto AZ verbs) → flip.

Shortest credible proof of the blob engine, zero platform risk (~a day): `git-storage` tests
(already green on this host) + `GitHostDfsTest`; then AZ routes; then a SECOND qits-artifacts
on a spare port with `QITS_REPOSITORIES_GIT_STORAGE=dfs`, import qits-stt's real history, run
the plan's three checks (ls-remote ref-for-ref, fsck clean, rev-parse match) + an `--atomic`
tag+main push. Rollback = `docker rm`.

## ROLLOUT COMPLETE 2026-08-03 — feature proven end to end (~34 min, no rollback)

The objective is met: `qits-ci-daemon` released through the train, published to qits-artifacts,
and qits-ci runs step containers from the published binary.

- Releases: qits-artifacts `2026.803.84843` (main `2728fc83`), qits-ci `2026.803.90241`
  (main `1e9a51ad`), qits-ci-daemon `2026.803.91607` (main `ce566d3f`). All deployments
  ACTIVE/healthy; epic branches auto-deleted by release.
- Pin moved: `QITS_CI_DAEMON_VERSION=ebc8fcc5…7a7f` (cd-config volume + generated compose,
  restart cd, redeploy ci — documented order held). `GET /ci/api/daemon` returns it. Proof run
  `da2d103b` SUCCESS with `daemonVersion = ebc8fcc5…`; old pin blob still serves (rollback
  intact; pre-edit run-args backed up in the session scratchpad).
- Daemon repo: bare created manually, main pushed at `b193d48` (parent, no trigger files — one
  build not two), epic at `30cc019`. Post-receive build `7acf456a` green in 6m25s (builder
  layers were warm). Self-seed adopted the repo after a qits-projects restart.
- Deliberate deviation: platform main ≠ epic tip before release because
  `ReleaseIntegrator.requireNotAlreadyIntegrated` 409s when source is ancestor of target.
- **New landmine found**: qits-artifacts' *release* run `467a960a` FAILED — its npm install
  raced the redeploy of qits-artifacts itself (post-receive run of the same commit). Its own
  pipeline header documents this ("deployed alone, with nothing else in the queue"). Cost:
  only the version-tagged image + its SoftwareRelease; SHA-addressed deployment unaffected.
  **Standing order: release a self-hosting repo only after its epic build drained the queue.**
- idp token endpoint is not reachable via gateway; call it on `qits-net`.
- BI shrank: this morning's cold bootstrap wiped the three measured orphans; the only rowless
  daemon blob now is the bootstrap-published old pin `fbefa249…` (uploaded via the OCI blob
  session, so no `daemon_binary` row — only train publishes are CalVer-addressed). Adoption is
  now one blob, or moot once the env is torn down for the storage experiment.

## Git storage: verified state (2026-08-03)

The DFS/blob git engine exists in qits-artifacts (`git-storage` module, both backends in the
deployed binary) but is inert: `qits.repositories.git.storage=file` pinned in
application.properties, no env override live. The volume (31 bares) is the real storage.
User's mental model ("nothing on the volume anymore") was stale — flip is DECISION PENDING in
git-host-storage-unification-plan.md.

## Security model settled (user decision 2026-08-03)

The daemon publish surface has the **same model as npm/maven/docker publishes: tokenless raw
surface on qits-net**. Integrity = digest pinning + immutable versions (409 on republish). No
publish surface is gated piecemeal — qits-idp gates all of them together when it lands. This
dissolved the former blocker (step containers carry no machine credential; `DaemonPublishGuard`
was briefly the platform's only guarded publish surface).

Follow-up commits (on top, nothing amended):
- qits-artifacts `05fa4df`: guard deleted; `DaemonOpenPublishTest` added as the fourth
  open-publish regression pin (gate on → anonymous publish 201, stray Authorization header
  tolerated, JSON admin API still 401) beside `RegistryOpenPushTest`/`NpmOpenPublishTest` and
  the MavenRoutes javadoc. Re-gating this surface alone now fails the build. Docs updated
  (AGENTS.md "What not to fix" records the guard existed for one commit and was removed as a
  decision). `./mvnw -o clean verify -Dquarkus.http.test-port=0`: 452 tests, 0 failures.
- qits-ci-daemon `30cc019`: 401/403 special-casing removed from the release publish step;
  409 hard-failure and digest echo intact.
- superproject `7d13c80`: bootstrap PUT is a bare curl again (`idp_token` dropped).

Notes from that pass:
- After a source deletion in qits-artifacts, a non-clean `./mvnw -o verify` fails misleadingly
  on stale `target/` test classes — use `clean`.
- Pre-existing drift: every qits-artifacts build rewrites `docs/openapi.yml` `info.version`
  (came in with release commit `088ad95`, uncommitted); kept out of these commits, will keep
  reappearing until someone commits it.

## BL: done (pending review + live proof)

- `daemons/qits-ci-daemon` commit `c913ece`: `.config/qits/ci-post-receive.yml` (mvn verify +
  docker:true musl native build with ldd/alpine smoke checks; the README's container-build=true
  recipe cannot work in a step container — `docker: true` is the host daemon, so `-v` paths
  resolve on the host; `docker build`/`docker cp` stream over the API and do work) and
  `ci-event-release.yml` (SCMRelease-triggered, CalVer check, tag checkout, build, PUT,
  `artifacts: [{type: daemon, name: qits-ci-daemon}]` — syntax confirmed against
  `CiEventTriggerParser`). Publish origin derived from `$QITS_MAVEN_REGISTRY_URL` (not
  `$QITS_REGISTRY`, which is host-daemon-facing). 409 is a hard failure (unlike maven/npm
  skip-if-published — republishing a daemon version would be a lie). Digest echoed last as
  `QITS_CI_DAEMON_VERSION=<hex>`.
- Superproject commit `7411ece` (`qits-local-up.sh` only): `ci-daemon` joined
  `RELEASE_TRAIN_REPOS` → bare + history pre-seed via direct fetch, **no post-receive fires at
  bootstrap** (pre-seed bypasses the receive path — good: a cold GraalVM musl build would race
  the serial deploy train for ~4 GB). Removed the now-duplicate `ci-daemon` from the sources
  loop. Upload switched to HEAD-probe + `PUT /artifacts/daemons/qits-ci-daemon/$DAEMON_SHA`
  (⚖5: version = digest hex; the `idp_token` auth added here was removed again by `7d13c80`,
  see the settled security model above). Compose pin and cd run-args untouched.
- Verified: `sh -n`, `git diff --check`, PyYAML parse of both files, `bash -n` on extracted
  step scripts. Nothing run against Docker or the live platform.
- Open supply-chain note: musl builder still `FROM localhost:8081/...` (works: host daemon
  resolves it) and fetches its toolchain from `more.musl.cc` per build — ship-the-ci-daemon §1's
  flag stands.

## Verified rollout sequence (checked against source + live platform, 2026-08-03)

User plan: push to `epic/ci-daemon-publishing` per repo, release one after another. Verified
findings that shape the order:

- `qits-ci-daemon` has been in qits-projects' self-seed manifest all along
  (`SelfSeedService.java:261`) — no qits-projects change or release needed. But adoption is
  conditional on the bare origin existing (`hasExistingOrigin`), and the live git host 404s for
  it. **Nothing on a running platform creates a name-keyed bare origin** — no API, no
  auto-create-on-push (`GitHostRoutes` returns 404), and `qits-local-up.sh`'s new seeding only
  runs at cold bootstrap. Manual volume act required (same as bootstrap):
  `git init -q --bare -b main /repos/qits-ci-daemon/origin` + `chown -R 1001:0`.
- Self-seed adoption runs only on `StartupEvent`; `POST /projects/{id}/reconcile` does NOT
  re-run it → qits-projects must be restarted after the bare exists.
- qits-ci parses ALL trigger files at event receipt; the deployed enum lacks `daemon`, so
  releasing the daemon before new qits-ci yields **no run and no error** — one WARN, nothing
  else. Silent. New qits-ci must be live first.
- Old qits-artifacts serves HTML (SPA catch-all) at `/daemons/...`; new one must be live before
  the daemon release's PUT. Seeder runs on every startup; V10 FK is satisfied then.
- A repo becomes a CI candidate only via the receive path (`KnownCiRepos` = run rows ∪ bare
  caches): pre-seeding the bare by direct fetch fires nothing. The daemon repo's first pushes
  must go through the git host (protected default branch → `-o qits.token=$PUSH_TOKEN`).
- After the daemon release, the pin move stays the only remaining act; the current live pin
  keeps working meanwhile (blob GET is globally content-addressed, old bytes untouched).
- BI is confirmed a non-blocker: rowless blobs are reported and left alone; no
  `DAEMON_BINARIES` GC strategy exists (BK deferred), so nothing sweeps daemon blobs.

The sequence ([OPS] = ordinary operation, [MISSING] = no supported path, manual):

1. [OPS] Push the six commits to `epic/ci-daemon-publishing` per repo.
2. [OPS] Release qits-artifacts; verify `daemons` row exists and `/daemons/x/y` returns a
   plain-text 404, not HTML.
3. [OPS] Release qits-ci; verify `GET /ci/api/daemon` returns JSON (404 today). Mind the known
   self-redeploy landmine (queued builds/post-receive rows can drop).
4. [MISSING] Hand-create the bare origin on the `qits-repositories` volume (command above).
5. [OPS] Push daemon `main` then the epic branch **through the git host** so `KnownCiRepos`
   learns it. Expect the epic push to fire `ci-post-receive.yml`: full verify + cold GraalVM
   musl build, ~30-60 min — first live proof of BL's post-receive pipeline.
6. [OPS] Restart qits-projects → self-seed adopts; verify
   `GET /projects/api/repositories/qits-ci-daemon` → 200.
7. [OPS] Release `epic/ci-daemon-publishing` of qits-ci-daemon through Workspaces.
8. [OPS] Verify: run row with `parentId` = SCMRelease, PUT 201, `SoftwareRelease {daemon,
   qits-ci-daemon}`, step output ends `QITS_CI_DAEMON_VERSION=<hex>`.
9. [OPS] Move the pin: cd run-args volume + `docker-compose.qits.yml` env, restart qits-cd,
   redeploy qits-ci — in that order.
10. [OPS, optional] BI adoption → `orphanBytes = 0`, empty the AZ allowlist.

## BH: done (pending review)

qits-artifacts commit `bf2c5f0` on `main`, not pushed. `./mvnw -o verify
-Dquarkus.http.test-port=0`: 453 tests, 0 failures (was 421). Native profile not run.

- Migration is **V10**, not the plan's V6 — the lineage had moved on (V6–V9 landed since the
  plan was written). `daemon_binary` PK `(repository, name, version)`.
- `RepositoryType.DAEMON_BINARIES`, seeder `daemons` row, `DaemonRegistryService`, wire routes
  under `/daemons` (raw Vert.x, streaming, 409 on republish, response carries digest).
- Quinoa `ignored-path-prefixes` gained `/daemons` — without it the SPA catch-all serves
  index.html to the bootstrap's curl-and-exec.
- Plan contradiction 1: `ArtifactsTokenFilter` no longer exists and JAX-RS filters never run on
  raw Vert.x routes. BH shipped a `DaemonPublishGuard` instead; it was removed one commit later
  by user decision (see the settled security model above).
- Plan contradiction 2: no `BodyHandler` at all (maven-route precedent, streams through
  `OciRequestBody`); cap knob `qits.artifacts.daemon.max-binary-size` (default 256M) is the only
  bound.
- AZ has landed; census wiring went into the real `LiveBlobCensus`. `StoreSummary` gains
  `daemonBinaryBytes`. Stale ELF-orphan javadoc amended.

## BJ + DAEMON type: done (pending review)

qits-ci commit `902ba4b` on `main`, not pushed. Full reactor green:
`./mvnw verify -Dquarkus.http.test-port=0`, 284 JVM tests, 0 failures (ITs skipped as usual).

- `GET /ci/api/daemon` → `{"daemonVersion": ...}` from the configured value
  (`CiDaemonController`). Anonymous read; exposed in OpenAPI (agent judged the "machine surfaces
  stay out" criterion to mean "contract lives elsewhere", recorded in that repo's AGENTS.md —
  flip if you disagree).
- Boot shape check is a WARN, not a startup failure, and only fires when the URL template
  contains `sha256:{version}` — so a future ⚖2(b) flip to version-addressed pins retires the
  check instead of false-alarming on calver values.
- `CiArtifact.Type.DAEMON("daemon")`; vocabulary string now derived from `values()`. qits-ci is
  type-agnostic end to end — it only announces; the actual upload is a pipeline step in the
  daemon repo, same as npm/maven/docker. So BL's publish step carries the PUT.
- Note: the submodule sat detached at `4590758` (== origin/main); agent fast-forwarded local
  `main` there and reattached before committing. No history rewritten.
- Pre-existing doc drift found, left alone: qits-ci CLAUDE.md/AGENTS.md still describe the
  removed `CiTokenFilter` (now `MachineAuth` + `qits.auth.machine.required`).

## Preserve

- Root untracked user files: `daemon-artifact-identity-plan.md`, `workspace-overview-ux.md`.
- `services/qits-workspaces/.claude/` is user-owned and untracked.
- Do not reintroduce EventStream as a CI/Workspaces submodule or reactor module.
- QuarkusTest on this host: pass `-Dquarkus.http.test-port=0` (8081 is the npm registry).
- Moving the daemon pin stays a human act: edit cd run-args volume + compose, restart qits-cd,
  then redeploy qits-ci — in that order (qits-cd caches run-args at boot).
