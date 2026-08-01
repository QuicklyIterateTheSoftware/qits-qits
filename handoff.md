# Handoff: 2026-08-01 evening → next session

Start here. What shipped today, how to verify it landed, and where the work picks up. The map, not
the territory — reasoning lives in the plan docs named inline. **Kept live during the session as
workstreams land; the "In flight right now" section is the part to re-check first.**

This morning's handoff is in git history (`git show 9bbee7c:handoff.md`): the integrate/release
split, the release event, the finished-runs rail, and the release train's first live hop. All of it
still stands, with one rename running through it — see below.

## The headline: the release event split in two

The SCM-release split, **SHIPPED AND OBSERVED** (plan verified fully implemented and retired
2026-08-01; the measured chain and rescued arguments live in docs/scm-release-split-notes.md);
this is the shape.

One event used to fire when the release *push* was accepted and every consumer read it as "the
package exists". Between those two statements sits a whole build. This morning's hop worked on
timing, not design. Now there are two events, each meaning one thing:

- **`SCMRelease`** — qits-workspaces, the instant the push is accepted. Payload unchanged
  (`{projectId, repository, branch, version}`). It means source control has this version.
- **`SoftwareRelease`** — qits-ci, when a repository's **release pipeline** goes green. Payload is
  `{repository, version, packageType, packageName}` and it is emitted **once per declared
  artifact**. It means the artifact is in qits-artifacts and you can install it.

Between them sits a release pipeline each repository owns: check out the released tag, build,
publish. The framework still knows nothing about publishing — `artifacts:` in the pipeline file is a
**declaration**, and qits-ci announces on the strength of it.

Five workstreams:

- **AK** qits-artifacts `a4fae38` — the tag mechanics measured on the real host (JGit accepts an
  annotated tag push), and the **`latest` guard**: a whole publish is refused **403** when it would
  move `latest` backwards. That closes the foot-gun a `-main.g<sha>` prerelease would otherwise fire.
  (Head is now `7e91db0e`, the styling fix on top.)
- **AM** qits-ci `97a1f0d` — `artifacts:` in a pipeline file, and the per-artifact
  `SoftwareRelease` fan-out on a green declared event-run, `parentId` = the triggering event.
- **AL** qits-workspaces `efe5acf` — the class rename (the wire name *is* the class name), the
  annotated tag pushed **atomically with `main`**, and **409 `VERSION_ALREADY_RELEASED`** when the
  version's tag already exists.
- **AN** — the two canary release pipelines, landed inert first because the bus has no replay:
  `libs/qits-spa-ui-components` `1964a78` and `services/qits-stt` `6398740`. Post-receive now
  publishes `<version>-main.g<sha7>` with an explicit `--tag main`.
- **AO** (this pass) — qits-events `298936d`, the V4 migration deleting the three rows that carried
  the old meaning, then the live proof of both chains.

### The proof, in one paragraph each

**npm.** A doc commit on `qits-spa-ui-components`, released as `2026.801.85149` (`21655ba4`).
Annotated tag `refs/tags/2026.801.85149` (object `69f6181f`) peels to the release commit and carries
its subject. `SCMRelease c5edabb5` → release run `9e62191e` (`EVENT`,
`ci-event-release.yml`, `triggerEventId c5edabb5`) checks out the tag and publishes; dist-tags end at
`{latest: 2026.801.85149, main: 2026.801.85149-main.g21655ba}` — **`latest` moved forward**. The run
yields two siblings under the same parent: `BuildSuccessful 99c733d8` and
`SoftwareRelease 0bdbe98d`. spa-home's bump trigger (now on `SoftwareRelease`, matching
`repository`) fires → run `5d42b91f` → force-push `maintenance/qits-spa-ui-components` `9e8666cc`
→ ONE run `e55d9131` with tests + release → spa-home releases `2026.801.85249` (`dd021e83`, tagged).
spa-home has no release pipeline, so **no `SoftwareRelease(qits-spa-home)`** and nothing wakes.
60 seconds, release call to last event.

**docker.** Same on `qits-stt`: `2026.801.85448` (`ccd55834`), tag object `7ec49abb`,
`SCMRelease 7bb9fc99` → release run `df62403a` →
`HEAD /v2/qits/qits-stt/manifests/2026.801.85448` = **200**, and
`SoftwareRelease f99998d3 {docker, "qits/qits-stt"}`. Beside it, unchanged: the ordinary
post-receive run `02eef2e6` pushed `qits/qits-stt:ccd55834` and deployment `cce9225a` went ACTIVE.
No repository consumes stt's artifact, so the train stops there.

**The one thing that could have broken and did not**: `SoftwareRelease` had never been serialized by
the deployed qits-ci **binary**. `bus/EventWireReflection` had it registered; the first real emission
came out whole. A JVM suite cannot see that class of defect, so it was open until this run.

### What the split changes for a reader of the old docs

- The event AJ and AG observed as `SoftwareRelease` is `SCMRelease` now. The pre-rename plans
  (release-flow, release-train-hops, software-release-event) were all verified and retired
  2026-08-01 rather than rewritten; their rescued arguments live in docs/*-notes.md (their
  success stories were true and also masked the race — both facts stay on the record there).
- **The train stops one event earlier in kind.** It used to stop at a repository that matched
  nothing. It stops at a repository with **no release pipeline**: the artifact statement is never
  made, so there is nothing to match.
- **Causation is a fork.** `?parentId=<SCMRelease id>` returns `N+1` children — one
  `BuildSuccessful` plus one `SoftwareRelease` per declared artifact — all at the run's finish
  instant. That query is the whole answer to "what did this release produce".

## Also shipped: the SPAs stop rendering in Times New Roman

Four SPAs carried the Angular scaffold's `styles.css` with **zero rules** in it, so they inherited no
platform typography at all — `qits-spa-artifacts` `1e85926`, `qits-spa-events` `225b7df`,
`qits-spa-observability` `bea5f2f`, `qits-spa-projects` `84691cd`. Fixed by taking the global
stylesheet the other four already had; **all eight are uniform now**. Each rode into its service on
the gitlink.

The related fix was **recommended and deliberately parked**: `index.html` is served
`immutable, max-age=86400` by every SPA, so a returning browser gets a stale page after each deploy
until a hard reload. Doing it per service is a seven-repo rollout; doing it **at the gateway** is one
change and covers every SPA at once. That is the recommendation and nobody has taken it.
**Until it is done, hard-reload before judging any SPA deploy.**

## Also shipped: the release pipelines fanned out (was "AP", done)

All eleven publishers carry `.config/qits/ci-event-release.yml` (8 more docker + the second npm,
`qits-integrations-angular` `40c42611`); ui-components' publish step is `branches:`-bound to main
(`d43d710f`) and spa-workspaces' canary listens to the true `SoftwareRelease` (`48114db8`). Every
deployment cycled green, one at a time. Known consequence recorded: on a service repo, a release
now produces a second same-sha deployment (any green run announces to cd).

## The afternoon, in order (all live unless noted)

1. **The artifacts explorer shipped end to end** — browse API (qits-artifacts, six read endpoints,
   manifest-parsed sizes) + the SPA (`qits-spa-artifacts` `aa51d3b`, repository-first tree, the
   labeled three-figure store summary, commit-sha tags deep-linking to `/ci/`). Live at
   `/artifacts/` (hard-reload). The census reconciles the store **to the byte**; gzip on (7.7×).
   Its plan doc was deleted after implementation.
2. **Git-host storage unification, most of the way** (`git-host-storage-unification-plan.md`,
   verdict PLAUSIBLE-WITH-PRECONDITIONS, all ⚖ settled: reftable; no GC recorded; mirror cache in
   its own module; both backends behind config; artifacts Flyway lineage):
   - **AT** qits-workspaces `e6f6b14` — the service no longer touches the shared filesystem: new
     `gitmirror` module (no Quarkus, simple API, extractable to a daemon later), every ref write a
     push, worktrees on a private mirror, the tag dance simplified. **The payoff observed live: a
     branch creation now produces a CI run where it produced silence.** Zero six-verb call sites
     here — they all live in qits-projects.
   - **AV** qits-artifacts `6f2af8c` — the `git-storage` module: DFS + reftable over two
     self-declared ports (PackBlobStore, PackCatalog), 18 offline tests incl. atomic refusal and
     the GC-amplification assertion.
   - **AW** qits-artifacts `bf9294d` — the wiring: adapters, `V4` pack catalog + `V5` protection
     row (the bare-config override is a table now, both backends), the `GitRepositoryProvider`
     seam behind `qits.repositories.git.storage` (default `file`; a typo fails boot), GitHostSuite
     runs 23 cases against EACH backend, and a packaged-binary DFS probe round-tripped clone/push
     with zero bares on the volume.
   - **Remaining**: AX (both-backend native matrix — blocked on a create-verb route), the six-verb
     API on qits-artifacts (scoped entirely by qits-projects' ~35 call sites), the qits-projects
     conversion, then AY (importer + one-repo-at-a-time rollout, **no bare ever deleted**,
     qits-artifacts last).
3. **Artifacts GC underway** (`artifacts-gc-plan.md`, all ⚖ settled: npm-proxy parked; docker
   keep-set = calver tags + cd ACTIVE pins + previous distinct sha, fetched fail-closed; row-less
   blobs UNTOUCHABLE this draft — daemon orphans deferred; **nothing deletes until the user
   reviews the dry-run**):
   - **AZ/BA** `da604b0` — the substrate: `LiveBlobCensus` (one census, shared with the explorer),
     `BlobStore.delete` package-private with a **7-day grace window** + pre-unlink re-census, the
     `GcStrategy` seam, and `GET /artifacts/api/gc/plan` (dry-run reports).
   - **BB** `a1d4030` — the oci strategy, live in the plan: **dead 270 / kept 21 / 4.48 GiB
     reclaimable (81.6% of the OCI union)** — all withheld by the grace window until ~Aug 6 (the
     store is two days old). Kept-by-rule spot-checked. cd pins fetched by enumerating ALL
     environments; `commitSha` is the field.
   - **BC** — the npm strategy + the republish **tombstone** (a GC'd version can never be
     silently republished), in flight at handoff-update time.
4. **The daemon-identity plan settled** (`daemon-artifact-identity-plan.md`; ⚖: type name
   **`binary`** (user's call), **version-addressed** pin URL (user's call), qits-ci pin endpoint
   fail-closed, release-train tie-in yes). Key corrections it measured: the ci-daemon has NO
   pipeline (only a bootstrap curl publishes it; neither daemon repo is on the platform git host),
   and the workspace daemon ships INSIDE `qits/workspace:latest` on the host docker daemon —
   nothing in the store at all. Workstreams BH–BL queued behind the GC chain.
5. **The pull-through mirror plan settled** (`proxy-pulling-normal-images.md`, SETTLED, uncommitted):
   generalized lazy pull-through, npmjs-style — the `oci_mirror_upstream` entity (domain → slug:
   docker.io→hub, quay.io→quay, registry.access.redhat.com→redhat; prefilled; CRUD-managed, UI
   panel to follow), append-only cache, anonymous upstreams (recorded: `docker login` never
   traverses a pull-through hop — private registries need a server-side credential, a future
   entity column). The one-time FROM rewrite is 24 lines in 12 repos; bootstrap's three Hub refs
   stay direct. Workstreams **BW→BX→BY→BZ, CA** (explorer panel) queued.
6. **The workspace detail screen, wave 1 done** (`workspace-detail-plan.md`, all ten ⚖ settled —
   the user refined two: lifecycle verbs are CONDITIONAL (release iff parent is main, integrate
   iff target is not), and **speech stays as far as the original existed** (recorder → qits-stt →
   refine), overriding the plan's kill recommendation. Letters AH–AQ renumbered **BM–BV**):
   - **BM** qits-workspaces `72cdeb3` — `GET /workspaces/{id}` (+ `repositoryMainBranch`), prompt
     draft/attachments, bootstrap-runs reader; ⚖9: `ENDED` survives in the rollup (30-min TTL,
     BUSY>WAITING>IDLE>ENDED); and the **websocket backpressure defect FIXED** (upgrades bypass
     vertx-http-proxy entirely; discriminating test). Endpoint shapes frozen in its report.
   - **BN** workspace-daemon `d2f17ae` (GitHub only; ships in `qits/workspace:latest`, host-built —
     picking it up needs a host image rebuild + per-workspace recreate, scheduled with BU) — the
     hand-written 24-operation API contract + both socket protocols, guarded by
     `OpenApiContractTest`; `/services` enriched (`restartCount`, `webView`). **Health machinery
     does not exist in the daemon** — declared checks are parsed but never run; no `health` field
     shipped; the prober is a named follow-up and the services panel builds for absence.
   - **BO** qits-spa-workspaces `278bb47` — the shell: detail route (`?tab=`), status strip with
     conditional verbs, activity bar (renders ENDED), tab host (latch-and-hide, in-session
     reorder), SSE client (invalidate-on-connect, zero timers asserted), daemon transport skeleton.
   - **BP** (files tree) in flight; then BQ (chat + prompt + restored speech) → BR (services +
     actions) → BS (files viewer) → BT (agents + web view + severable element picker) → BU (gitlink
     embed + ship + browser pass). BV = phase two.
7. **Sixteen plan documents verified and retired** by read-only verifier agents (ci-cd-explorer,
   event-triggers, dns, causation, eventsourcing, software-release-event, migration-deployables,
   main-environment, npm-registry, scm-release-split, final-workspaces, finish-ci, release-flow,
   release-train-hops, image-publishing, plus artifacts-explorer post-implementation). Every
   unique argument was rescued into **docs/*-notes.md** (causation, eventstream, ci-cd-explorer,
   npm-registry, release-flow, release-train, scm-release-split, workspace-daemon);
   `migration-plan.md`'s §9 ledger finally learned what shipped (items 9/16/19 closed, 22 gained
   the ci-daemon precedent). The one real gap found: run-page live-output auto-scroll (parked).
8. **Events + observability UI designs in flight** — two Opus agents writing `events-ui-plan.md`
   (letters CB+; knows `?limit=` is ignored and causation is the centerpiece) and
   `observability-ui-plan.md` (letters CG+; the store's ephemerality must be surfaced honestly).

## In flight right now (update on each landing)

- **BR** — services + actions tabs (qits-spa-workspaces; BQ landed `a3ea608`, 269 tests — chat
  with side-chain folding, prompt panel on BM's draft contract, and the SPEECH FLOW RESTORED:
  recorder → level meter + pause detection → WAV → live qits-stt `{audioBase64}→{text}` →
  serialized appends → refine. Shared seams for later workstreams: WorkspaceCommands,
  PickedContext. The user ruled TWO BOXES (the spec's original transcript→promote shape) — a
  small BQ follow-up queued for when BR frees the repo.)
- ~~CB~~ — events backend queries LANDED (final `9099c91`, deployed ACTIVE; envelope + literal
  cursor spelling regression-pinned; live walk 142/142 whole): honored/clamped limit,
  composite cursor (walked live: 20 pages, 140 ids, 0 dup/missing, forks intact), /names,
  ?name=/?since=/?q=, (occurredAt,id) total order. Envelope exactly {events, nextCursor}.
- **CE** — events live tail (qits-spa-events; CD landed the log page `a19dd83`, 78 tests, budget
  2+1-socket asserted, three bespoke gists, cursor-re-entry contract documented for the tail.
  CB is live, so the filters work against the real server already.)
- **BW** — mirror type + `oci_mirror_upstream` entity (qits-artifacts; **GC-BC landed `83d7b57`**:
  npm strategy live in the dry-run — 3 superseded prereleases dead / ~31 KB, tombstone V6 shipped
  with "removed by garbage collection" 403s. **THE FULL TWO-STRATEGY DRY-RUN NOW AWAITS THE
  USER'S REVIEW at GET /artifacts/api/gc/plan** — oci 4.48 GiB + npm 31 KB, all grace-withheld
  until ~Aug 6; the sweep trigger is not built until the review says go)
- ~~CH~~ — observability read surface LANDED (`7d61d07`, deployed ACTIVE): re-bucketing live —
  eight real service.name buckets within seconds, a real nested waterfall trace verified; all
  four SPA rulings honored (explicit nulls); schema wart fixed. NEW USER DECISION: no service
  exports metrics (quarkus.otel.metrics.enabled defaults false in all ten) — enable via a
  ten-repo fan-out, or ship the metrics screen honest-empty.
- ~~CI~~ — observability SPA foundation + Overview LANDED (`e7e5782`, GitHub-only; 35 tests;
  Overview budget 2+0 with zero-cost expansion asserted). Four contract seams it found were ruled
  and sent to CH as binding (thresholdMs + service on /traces; rootMissing always; nullable
  window/scope fields). The spa-side CI recipe file is reassigned to the embed workstream (CM).
- **CJ** — observability traces screens (qits-spa-observability, against CH's frozen live surface)
- Queued: BQ two-box follow-up + **BS** (SPA-workspaces, after BR), **CF** (events chain page,
  after CE), **BX** (miss path, after BW), **CK/CL/CM** (observability errors+logs, metrics,
  embed).
- New parked line from BP: the daemon doc under-describes `/files` (the root call returns the FULL
  eager tree, not one level; and `listDirectory` stubs every subdirectory) — a doc sentence for
  the daemon repo's next pass. BP's derived framework-depth rule (descend while exactly one
  subdirectory holds members, fork stops, cap 6) is a recorded judgment call.

## Next up (decisions and follow-ups awaiting the user)

- **Review the GC dry-run** (`GET /artifacts/api/gc/plan`) once BC lands — the gate before any
  sweep; the grace window means nothing is reclaimable before ~Aug 6 regardless.
- **`workspace-overview-ux.md`** — still awaiting the concept choice (workspace-detail is being
  implemented; artifacts-explorer shipped).
- **The gateway `index.html` cache header** — one change at the gateway, seven SPAs' benefit,
  user-facing. Until then hard-reload before judging any SPA deploy.
- **Typography tokens in ui-components** — the durable form of the styling fix; wants the train
  fan-out (six SPAs) so consumers actually pick up lib releases.
- **The daemon health prober** — BN measured the machinery absent; shape specced in its report.
- **Docker release-step idempotency** (rebuild-and-repush on redelivery vs a manifest probe) and
  the **summary-length composition** (108 vs the 100 cap) — both still undecided.
- **Tag GC** — release tags are permanent refs now; the GC plan's git strategy never deletes refs
  by design, so if tag pruning is ever wanted it is its own decision.

## Parked follow-ups (deliberate, not forgotten)

- **The other six SPAs' train files** — still a fan-out awaiting the user's go. Seven bump runs,
  seven maintenance pushes and seven releases on one serialized worker.
- **Retired-plan pointers in submodule docs.** Nine verified-shipped plans were deleted 2026-08-01
  (explorers, event-triggers, dns, causation, eventsourcing, software-release-event,
  migration-deployables, main-environment, npm-registry, scm-release-split; rescued
  arguments live in docs/*-notes.md). Still pointing at them, to fix on each repo's next real
  change (never a deploy of its own): qits-ci AGENTS.md:91 (its "kept alive only by
  eventsourcing-plan.md" sentence is now false) and :351; qits-events AGENTS.md:131;
  libs/qits-eventstream README:12 + QitsEvent.java:17 (plus the two vendored submodule copies);
  qits-dns service/pom.xml:90 (stale SimpleResolver claim); seven service pom.xml headers citing
  migration-deployables-plan.md (artifacts, cd, ci, observability ×2, projects ×2, stt ×2,
  workspaces) + qits-observability README:173; two stale prose strays (observability
  service/pom.xml:35 "still library JARs", qits-stt README:107 "not yet a deployable");
  ~25 cites of main-environment-plan.md across 20 qits-projects files (rationale restated in
  code everywhere — pointers to strike, not knowledge to migrate); qits-workspaces AGENTS.md:522
  and libs/qits-spa-ui-components README:140 citing scm-release-split-plan.md;
  frontends/qits-spa-home README:168 + ci-post-receive.yml:88 still saying the release "publishes
  a SoftwareRelease" (post-split it is SCMRelease); qits-workspaces DaemonApiGateIT.java:35 citing
  the retired final-workspaces plan; StepChunk.java:10 in BOTH protocol copies (daemon repo first,
  then the vendored qits-ci copy, or diff -r goes red) + CiDaemonRegistry.java:148 citing the
  retired finish-ci plan; qits-workspaces README:271 (future tense for shipped daemon routing, and
  "a gateway route" is what the design forbids); workspace-daemon AGENTS.md:110 (names
  SameOriginUpgradeCheck as open — the gateway resolved it, the class does not exist);
  qits-workspaces AGENTS.md tests note ("real-docker ITs are not in this repo" — DaemonApiGateIT
  is, self-skipping); qits-workspaces VersionStamp.java:36 + NpmVersionBumper.java:42 citing the
  retired release-flow plan (redirect to docs/release-flow-notes.md); three stale strays the
  release-flow verifier found — qits-workspaces GitExecutor.java:101 ("the overload the integrate
  flow's push uses" — no production caller since gitmirror), qits-artifacts
  microprofile-config.properties:127 (still teaches the bare-config override and "owns no table"
  — it owns three, the override is a row), qits-artifacts README:154 (names /integrate as the
  release door — it is /release), qits-artifacts README:921 (still claims steps get no docker
  socket "by design" and builds keep failing — false since image-publishing shipped; all nine
  services are built exactly that way).
- ~~The websocket backpressure defect~~ — FIXED same day (qits-workspaces `365ea90`, workstream
  BM): upgrades bypass vertx-http-proxy entirely, raw NetSocket piping with full flow control,
  proven by a discriminating test. Record kept in docs/workspace-daemon-notes.md.
- **qits-dns is built but deployed nowhere, and no plan owns that.** Verified 2026-08-01: no
  container, no compose entry, not in qits-local-up.sh's sets, no gateway route. Consequence today
  is nil (the only project stores no dns record, so the registrar never fires), but it is orphaned
  platform debt — recorded here so it has an owner-shaped line, not just the bootstrap's warn.
- ~~The spa-workspaces trigger flip and the ui-components publish binding~~ — both closed by the
  fan-out workstream (qits-spa-workspaces `48114db` flips the canary to `SoftwareRelease`;
  qits-spa-ui-components `d43d710f` binds the publish step to `main`).
- The `summary` length composition (a release subject quoting a bump subject reaches 108 against a
  100-char cap) — unreachable in the designed flow, still undecided.
- Tofu chevrons (`▸▾`) in the explorers on hosts without glyph coverage.
- `CausationStampingTest` and `OutboxFlowTest` flakes in qits-eventstream — same outbox race.
- qits-ci README still promises `jq` in step images; `node-base` has none.
- qits-spa-ci / qits-spa-cd have CI recipes but no repos on the platform git host.
- Event-triggered QUEUED rows are discarded (not re-enqueued) at restart.
- DAG cycle detection across trigger files; bus catch-up/replay.

## Operational truths that bite (full versions in auto-memory + repo AGENTS.md files)

- **Two release events, and they are not interchangeable.** `SCMRelease` = source control has the
  version. `SoftwareRelease` = the artifact is published, and it names the exact package. A
  downstream consumer triggers on the **second**. A repository with no release pipeline emits no
  `SoftwareRelease` at all — that is the designed stop, not a break.
- **Three endpoints, two doors.** Release is the only thing that writes `main`:
  `POST /workspaces/api/workspaces/{id}/release` and
  `POST /workspaces/api/branches/release?repositoryId=<repo>` `{branch, summary}`. Both stamp, bump,
  **push an annotated tag named the version atomically with `main`**, publish `SCMRelease`, resolve
  any ACTIVE workspace on the branch INTEGRATED and delete the source branch.
  `POST …/{id}/integrate` merges into the branch's *parent* and refuses a `main` parent with 409
  `RELEASE_REQUIRED`. A direct `git push … main` needs `-o qits.token=local-dev`.
- **409 `VERSION_ALREADY_RELEASED` is retryable** — the version's tag already exists, and a second
  later a fresh stamp simply works. Never treat it like `PUSH_REJECTED`, which is not retryable.
  It is reachable on a small repository: two releases inside one second stamp one version.
- **A release pipeline checks out the tag, not `main`.** An event-triggered run is cloned at the head
  of main, which a later push moves; the tag does not. `git fetch <url> refs/tags/X:refs/tags/X &&
  git checkout --detach X` is the whole mechanism, and it needs no platform change.
- **`artifacts:` is a declaration nobody validates.** qits-ci announces `{repository, version,
  packageType, packageName}` on the strength of two lines in a YAML file. A wrong `name:` produces a
  confident event about a package that does not exist.
- **`@` is a reserved YAML indicator** — `exact: "@qits/ui-components"` must be quoted.
- **npm `latest` is guarded now** (403 on a backwards move), but a prerelease publish still needs
  `--tag main` — the guard refuses the whole publish, so a missing `--tag` is a red build, not a
  silent regression.
- Replays of `POST /ci/api/events/post-receive` are NOT idempotent; a missing run row while the
  worker is busy means QUEUED, not lost. A run whose sha was force-pushed away is discarded outright.
- qits-cd write-wedge: green runs, no deployment row, "database has been closed" in cd logs →
  restart the cd container, replay `POST /cd/api/events/build-succeeded`.
- qits-cd caches its run-args config at boot; restart it after editing the `qits-cd-config` volume.
- Gateway is :8080; :8081 is qits-artifacts direct (and the reason every repo's test port is 0).
  CI filter param is `repositoryId`; cd's is `environmentId`. `/events/api/events` ignores `limit`
  and returns the whole history.
- **GC never runs on its own.** `GET /artifacts/api/gc/plan` is a dry-run report; the delete
  primitive is package-private with a 7-day grace window and a pre-unlink re-census; row-less
  blobs (the 130 MB orphan pool incl. the live ci-daemon binary) are untouchable by construction.
- **The git host has two storage backends.** `qits.repositories.git.storage` = `file` (default) |
  `dfs`; an unknown value fails the boot on purpose. DFS repos cannot yet be created from outside
  the process (the create verb has no route until the six-verb API lands).
- `ENDED` agent activity expires from the rollup after 30 minutes
  (`qits.workspace.agent-activity.ended-ttl-ms`); precedence BUSY>WAITING>IDLE>ENDED.
- Never run `qits-local-up.sh` casually (the recreate branch kills the cd-managed core); never DELETE
  the `qits` project (it deletes the platform's own git origins).
- Superproject: many local commits, **none pushed** (the user has not asked). Submodule gitlinks lag
  by design; sync is automated.

How to verify any of it: `/ci/api/runs?repositoryId=<repo>` for builds,
`/cd/api/deployments?environmentId=9fc2480c-3ff9-4f24-9bfe-67abe64afb06` for deployments,
`/events/api/events` and `?parentId=` for the bus, `git ls-remote` on both remotes for shas **and
tags**, `HEAD /v2/<repo>/<image>/manifests/<tag>` on :8081 for a docker artifact, and
`GET /artifacts/npm/npm/<pkg>` for an npm one.
