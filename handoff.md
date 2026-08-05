# Handoff

Updated 2026-08-05. The ci-daemon objective (artifact identity, release-train publish,
auto-adoption) is met and proven live; its workstreams, decisions and rollout history were
removed from this file. History is in git.

## In flight right now

- **GC per-repository + UI: SHIPPED AND BROWSER-VERIFIED 2026-08-05.** Backend
  `085b39a`+`6b164e1`, SPA `191e4f6`, embed `b0718dd` — deployed healthy, gitlinks
  `0168ac9`. `GET /gc/repositories` answers all 10 rows live; the explorer root shows
  the Cleanup column + Review cleanup per row; `repositories/:repo/cleanup` renders
  the dry-run (rule sentence, H2 honesty, kept-with-rules, pins provenance with
  timings, untouchable line) and — with nothing condemned — NO run button, just
  "There is nothing to run". Screenshot-verified both pages.
  **Pending user verdict**: the new lede (drafted, live) + two copy nits seen in the
  screenshot: the repository count runs into the lede unpunctuated ("10 repositories
  Two things…"), and excluded rows show "nothing" in the column where "not collected"
  would be more honest. Batch all three into one SPA copy commit after the user's
  lede verdict.
  Original design record (plan at scratchpad/per-repo-gc-plan.md):
  Design core (planner-verified): groups never span repositories, so per-repo is
  `Plan.scopedTo(repo)` — a FILTER over the one plan, never a second planner; the
  correctness case is a blob dead in two repos (must stay retained in each scoped
  view — dedicated test). Honest bytes = scoped reconcile ("blobs only this repo's
  cleanup frees"); Σ(per-repo) ≤ global, stated on the wire. Routes are subresources
  (`/gc/repositories/{repo}/plan|sweep`) because a dropped query param on the sweep
  must 404, never degrade to global. List column reads ONE derived summary call (a
  per-row plan = N censuses + 2N pin fetches — rejected). Sweep safety survives
  scoping via three belts (scoped retained-union, post-delete re-census, in-lock
  guard). UI: Cleanup column (structural figure + pins-down marker — ⚖C decided),
  details ROUTE `repositories/:repo/cleanup` = the review step, run button only
  below the rendered plan, two-press confirm (mirrors idiom), receipt in place.
  ⚖A decided: gitlink advance ships the 4 pending SPA commits (released content).
  ⚖B pending USER review: the repositories-page lede replacing "Nothing here
  deletes, expires or reclaims a byte" — implementer drafts, user vetoes.

- **Artifacts GC unblocked** (2026-08-05): the four ⚖ are SETTLED — and they supersede
  the plan's five-strategy shape. Settlement recorded at the top of artifacts-gc-plan.md
  (committed `5b8bfd6`): two generic strategies configured per repository type (cache
  types: delete unaccessed after $configured days; own types: always keep the last
  released versions, delete the unaccessed rest), live pins fetched at sweep time from
  qits-cd (owns "rollback-relevant"; unreachable aborts) and qits-ci `/ci/api/daemon`,
  and the engine extracted into its own maven module (`qits-artifacts-gc` — a process
  modeled in qits-artifacts, not artifacts domain). ⚖1 npm-proxy dissolves into the
  cache strategy; ⚖3's rowless blob needs no adoption — pins decide. BK (daemon GC)
  dissolves into the own-type strategy. A Plan agent is grounding the workstreams
  against real code (types, access tracking, census, cd/ci pin surfaces, module shape,
  "last released" semantics per type — ambiguities come back as ⚖, not guesses).
  Standing rule unchanged: nothing deletes a byte until the dry-run report is reviewed
  (re-armed: the bespoke-strategy review does not cover the new policy).
  **Planner ground truth**: most substrate ALREADY SHIPPED in qits-artifacts (census,
  BlobSweep w/ grace window, GcStrategy/GcPlanner/GcSweepExecutor, six bespoke
  strategies incl. cd-pin fetch, GET /gc/plan + POST /gc/sweep) — the reshape re-doors
  policy, it does not greenfield. Gaps: access tracking covers only 3 tables (V9);
  rollback policy lives in artifacts not cd; per-type fail-closed ≠ settled whole-run
  abort; git host is structurally excluded (not a RepositoryType); H2 row deletion
  reclaims no disk without SHUTDOWN COMPACT.
  **Residual ⚖ resolved** (committed `aa44728`): own belt = LAST 2 released versions
  (user's original words — access window + pins protect the rest); ci-screenshots/
  videos excluded for now (future own-like strategy); windows P30D/P90D as proposed;
  row-less legacy daemon blobs deleted BY HAND once (dev leftovers; no invariant
  weakening; the configured digest bottom rung may lose its blob — accepted).
  **Workstream sequence**: BI (access columns, artifacts) ∥ BL (cd pins endpoint) →
  BH (extract qits-artifacts-gc module, behavior-neutral, /gc/plan byte-identical) →
  BJ+BK (engines + config + pins aggregation + whole-run abort; swap the artifacts
  fetcher to /cd/api/pins and delete its local policy copy) → BM (cache adapters:
  oci-mirror, npm-proxy) → BN (own adapters: oci, npm, maven, daemon) → BO (report
  finish, doc supersession — the "no shared policy" rule must be rewritten as a
  DECISION, review choreography, first sweep after user review).
  **BL DONE** (qits-cd `5c091c6`, not pushed): `GET /cd/api/pins` — policy in
  `RollbackPins` beside DeployService, anchored to the cutover invariant and PROVEN by
  driving the real failed-gate/cutover flows. **Found a real bug in the artifacts-side
  rule it transplanted**: `Pinned.read` stops at the first older row of ANY status, so
  `ACTIVE/FAILED/DECOMMISSIONED` history pins a sha that never ran and drops the one
  that served; cd's rule skips never-served rows (FAILED/IMAGE_MISSING/QUEUED/STARTING)
  instead. Union is documented as a keep-SET (no cross-environment recency). Verify
  green (16+50+9).
  **BI DONE** (qits-artifacts `349f966`, not pushed): V11 `accessed_at` + V9-shaped
  indexes on npm_version/maven_artifact/daemon_binary, NO backfill (null =
  never-read-since-tracking, V9's reasoning mirrored); touches on npm tarball (one
  route covers hosted AND proxy — npm_version is shared), maven stored file, daemon
  version route; HEAD counts; touch only after the blob is located. Deliberately NOT
  tracked: digest-addressed daemon reads (cross-repo attribution is what V9 refuses;
  the live pin template uses the tracked version route anyway — verified) and maven
  derived documents. maven/daemon have NO browse surface (nothing to mirror accessedAt
  into — reported, not invented). 493 tests green.
  **BH DONE** (qits-artifacts `95b6752`, not pushed): `gc/` module landed
  (gc → artifacts only; service → gc; controller stays in service); three narrow
  facades (`BlobReclaim`, `OciRegistryCollection`, `NpmRegistryCollection`) — no
  funnel became public; **neutrality PROVEN**: seeded non-trivial /gc/plan report
  md5-identical before/after (3702 bytes, only generatedAt normalized). Fixture split
  kept the no-shared-test-classpath rule (deliberate documented copy). Real baseline
  was 452 tests (BI's 493 figure was stale), preserved exactly: 115+18+38+281.
  **BJ+BK DONE** (qits-artifacts `3796f04` + `dee03f9`, not pushed): engines
  (`CacheEvictionStrategy`, `OwnArtifactsStrategy` w/ RELEASES_KEPT=2) + adapter seam
  (`GcTypeAdapter`/`GcCandidate`/`GcPinned`) shipped DARK — seeded dead/kept snapshot
  across all 8 types provably unchanged; report gains the configuration echo. Pins:
  `GcPinSources.fetch()` once per run, both sources always asked; sweep aborts WHOLE
  on incomplete pins (untouchable pool "not computed", zero rows touched); plan never
  500s — `executable:false` + pinFailures, non-pin types still planned; cd fetcher now
  reads `/cd/api/pins`, local ACTIVE+previous derivation DELETED; ci blank version =
  answer; 64-hex pins the blob directly. Keys renamed to `gc.pins.*` — qits-local-up.sh
  verified NOT carrying the old key. 526 tests green.
  **DEPLOY ORDER LANDMINE: qits-cd (pins endpoint `5c091c6`) must deploy BEFORE
  qits-artifacts** — the new fetcher reads /cd/api/pins which live cd does not serve
  yet; until cd deploys, artifacts' plan reports non-executable and any sweep aborts
  (fail-closed, correct, but the report is what the user must review).
  **BM DONE** (qits-artifacts `967676a`, not pushed): both caches live on
  `CacheEvictionStrategy` (P30D). Mirror: tags + untagged child manifests are
  identities (evicting an unpulled architecture is the lazy-pull bargain — bytes
  survive via the kept index's closure); `collectTag` cleans `oci_mirror_tag_check`
  in-funnel. Proxy: proxy-only `npm_version` rows + packuments (staleness =
  max(fetched, newest version access) — never evicted under an active package);
  eviction funnels refuse non-proxy repos, write NO tombstone. H2 honesty note in the
  report; SHUTDOWN COMPACT documented as ops. Both caches `readsPins()` (digest pins
  reach cache rows because blobs dedupe) → live dry-run shows caches "pins
  unavailable" until cd's pins endpoint deploys — accepted. 501 tests green.
  **BN DONE** (qits-artifacts `c799886` + `7ccfd29`, not pushed): all four own types
  on `OwnArtifactsStrategy` via `OwnGcStrategy` binder (refuses incomplete pins /
  wrong engine; enumerates once). Belts carried with tests: calver last-2 (numeric
  three-part order), cd pins, newest-build-per-image (by tag updated_at — deliberate:
  cold never-deployed images), dist-tags, tombstone-in-tx, maven newest-resolvable
  snapshot set. Conservative §3.6 resolutions: maven identity = coordinate not path
  (jar+pom one identity); no keep-N-per-snapshot-line invented (window decides);
  grace withholds whole coordinates; oci unclassified-keep backstop retired into the
  access rule (measured store has none). NEW funnels: DaemonRegistryCollection,
  MavenRegistryCollection (no tombstones — daemon re-release at a collected version
  is legitimate). All own types readsPins() (digest pins reach any type's bytes).
  526 tests green (gc 110).
  **BO DONE** (`d4fcb70`): pins[] on plan AND receipt, human-first summary block,
  excluded lines on the type entries, doctrine rewritten as the 2026-08-05 decision,
  first-sweep choreography in README ops. SPA panel skipped (JSON is the review
  surface).
  **DEPLOYED 2026-08-05**: cd `5c091c6` then artifacts `d4fcb70`, both healthy;
  `/cd/api/pins` live (10 apps, 20 shas — ACTIVE+previous per app); `/gc/plan`
  EXECUTABLE.
  **Legacy row-less blobs HAND-DELETED** (user decision): all six (two daemon-sized,
  fbefa249 among them, three probe fragments; 124.7 MB) rm'd from the volume;
  **orphanBytes = 0** — the BI remnant is closed. Untouchable invariant untouched.
  **LIVE DRY-RUN, awaiting user review** (the gate before any sweep): executable
  true; 0 condemned / 0 B reclaimable — honest for a 2-day-old platform (every row
  younger than every window; last-2 belts hold everything current). Pins verified
  live: cd 10 apps/20 shas incl. today's deploys, ci 2 adopted ladder rungs. First
  sweep would be a no-op today; the report becomes interesting as the platform ages
  past P30D.

- Nothing running. **LF DONE (2026-08-05, orchestrator-measured):** identity rollout
  deployed fleet-wide (cd `3f71647` handoff clean, idp `647a3b7` with token endpoint
  verified post-cutover, five more services redeployed; 10/10 healthy). Verified live:
  `OTEL_RESOURCE_ATTRIBUTES` + `QUARKUS_OTEL_RESOURCE_ATTRIBUTES` on containers with
  full deploy sha / environment / instance id; the store RETAINS resourceAttributes but
  `TelemetryLogDto` omits them — **follow-up: expose service.version in the query API/
  UI**. Outage drill: `docker restart` on the receiver — 30/30 availability probes 200
  on qits-ci throughout, buffer honestly reset, all 10 sources re-exporting after.
  Latency: ≤35s measured across the receiver's own boot window (upper bound; steady
  state is governed by the SDK's ~1s batch delay — startup edge includes the exporter's
  throttled retries while its own receiver boots). **Secrets audit: CLEAN** — 66 live
  records, zero hits for the push token, all five idp client secrets, bearer JWTs,
  Authorization headers, passwords. Eviction counters zero through the deploy burst.
  Named follow-ups: **resource identity exposure DONE + DEPLOYED 2026-08-05**
  (qits-observability `bde4f4a`+`8bc5769` with embedded spa `97df6dd`: whole
  `resourceAttributes` map on log/span/metric DTOs, RESOURCE pane on the trace page —
  service.version first — and per-member version chips on the errors page; verified on
  a live record carrying the deploy sha, and screenshot-verified in the browser; a
  service shows full identity after its first post-LD deploy, pom stamp until then);
  qits-ci success-path
  daemon-tail capture — **assessed 2026-08-05 and DROPPED**: the tail is already
  captured on all three failure outcomes where it is the only diagnosis; on success it
  would cost a docker call per step to tee redundant housekeeping lines into the
  bounded live buffer. No change made.
  **LD-b (workspace ServiceSupervisor OTLP overlay) is OUT OF SCOPE by user decision
  2026-08-05** — no plan to stream telemetry from workspace-launched dev services for
  now. The plan's §LD second half is declined, and qits-observability's README note
  about the "missing sender" stays a description, not a TODO.

- **Items 1–5 recap** (2026-08-05, four Opus agents, disjoint repos): (1) LC-idp DONE
  (`647a3b7`, 20 green): extension + endpoint + logs.enabled were already present; the
  three handler/exporter/level keys, the full comment block, OtelLogConfigTest, and
  `quarkus.otel.metrics.enabled=true` (idp was the ONLY repo without it) added. No new
  dependency → no native surface change. Deploy note: idp authenticates everyone —
  watch its canary deploy longest;
  (2) LD-a — qits-cd injects `OTEL_RESOURCE_ATTRIBUTES` (service.version=deploy sha,
  deployment.environment.name, service.instance.id=container name) into every `docker
  run`, composing with operator run-args, precedence verified — plus cd's openapi
  re-export as a first commit; (3) LE DONE — decision record, no daemon code (correct
  outcome): BOTH daemons are Quarkus command-mode native (the plan guessed wrong — the
  ci-daemon is not Go), neither has trace context, so per the plan's own criterion both
  stay on console capture. ci-daemon: its own stdout reaches operators only via the
  bounded `docker logs --tail` on the three failure outcomes (success-path lines die
  with the container — named follow-up in qits-ci: capture/tee the tail on success too,
  three call sites, has a per-step docker-logs cost, decide before doing).
  workspace-daemon: 13 hand-written DaemonLog frames DO reach observability via the
  registry relay; the 40 ordinary Logger calls go to container stdout only — its
  overstating properties comment fixed + pushed (`8ea3cee`). In-process exporters for
  in-process exporters for both are NOT PLANNED (user decision 2026-08-05; LD-b
  declined). No OTLP endpoint is injected into workspace containers (zero OTEL_ refs in
  either daemon repo) and none will be — console capture is the answer, full stop. Bootstrap: out of
  scope, attended terminal output, circular by construction; (4) openapi sweep DONE — pure version-stamp diffs everywhere, no
  route drift: observability `ff176a0`, projects `8e1c934`, stt `3ee2970`, workspaces
  `fdfc01b`, artifacts `b781853`; events has no export test/docs at all. Side note:
  artifacts publishes `paths: {}` (raw-route service — its whole surface is invisible
  to OpenAPI; fine but worth knowing). Then: LF measurements (LD-b was later declined —
  see above). **LF's "secrets
  sweep" is an AUDIT, not a feature** (user confirmed scope): grep the live window for
  leaked credentials, record findings; automated redaction stays a future Collector
  concern (plan option B).

- **Log streaming: LA+LB+LC COMPLETE AND DEPLOYED PLATFORM-WIDE** (2026-08-05). All
  nine local services (dns has no local platform) deployed serially with per-service
  live-log canaries confirmed: events 8, cd 18, gateway 12, observability 6, projects
  16, stt 3, workspaces 16, artifacts 14, ci 20. Platform 10/10 healthy, daemon pin
  intact (adopted 2026.803.184200). 7/10 source buckets show logs (idp + the two
  probe-era buckets idle — idp never got the LC pass, it is not in the plan's table;
  flag for LD/LE triage). Gitlinks synced at root `9644d4b`. REMAINING: LD (deployment
  identity — service.version is stale pom stamps), LE (ci-daemon + workspace-daemon +
  bootstrap scripts), LF (live measurements: latency, burst, outage/recovery, secrets
  sweep), LG (durable retention, separately approved). Details below.
  **LA DONE — GATE PASSED** (qits-events `0bd5dbd`, not pushed): unchanged JBoss `Logger`
  calls reach a decoding OTLP stub in JVM, fast-jar AND real native (2:26, verified ELF).
  Exception attrs are exactly `exception.type/message/stacktrace` (semconv-stable); body
  stays the formatted message; no-span records carry ABSENT trace ids (empty, not
  zero-filled); one 500 yields several records at several severities (match severity+
  stack, not stack alone); INFO=9 ERROR=17. `quarkus.otel.logs.level=INFO` is a
  deliberate narrowing (real default ALL — comment says so). Unreachable receiver: 3000
  records past the 2048 queue, caller never blocked, health stays UP. New under
  service/src/test: OtlpLogStub (decodes), OtelLogBridgeTest, unreachable test,
  PackagedLogBridgeIT. proto artifact test-scope only.
  **LB DONE** (qits-observability `cfaba4c`, not pushed): `CanaryLogStreamTest` (8 cases
  through the public API: source bucket, severities, errors feed w/ stack trace, trace
  correlation, second batch, 400, 413-via-raw-socket, restart truth) + packaged
  `OtelReceiverIT` case; JVM 72 green, fast-jar ITs 16 green, REAL native gate green
  (1:28, verified not the docker fallback). **OTLP audit recorded**: success path
  compliant; error bodies are JSON not google.rpc.Status; no 429/503/Retry-After
  (deliberate fail-open — record as absent-by-design); no partial_success though
  evictedLogs holds the data; **finding 6 = real bug: gzip bomb — FIXED** (`9927937`):
  counted 8 KiB streaming inflate against the config-sourced ceiling
  (`quarkus.http.limits.max-body-size` via MemorySize injection), 413 past it, bomb test
  holds only the ~65 KB compressed form; native gate re-run green (@ConfigProperty
  injection points are build-time).
  **Deploys in flight**: qits-events `0bd5dbd` + qits-observability `9927937` pushed to
  GitHub + platform (gitlinks `c51fd3b`); watcher confirms cutovers then probes the live
  telemetry sources for the first real streamed logs.
  **LIVE CANARY CONFIRMED** (2026-08-05 ~10:10Z): qits-events `0bd5dbd` +
  qits-observability `9927937` deployed healthy; the live source list shows real
  streamed logs — qits-events 8 (incl. its native "started in 0.048s" line), cd 2, ci 1,
  observability self-export 6, no recursion blowup. Startup line still stamps the old
  pom version (2026.803.170350) — `service.version` is LD's territory.
  **LC wave 1 DONE + deploying**: qits-dns `785d812` (87 green, guard proven
  non-vacuous), qits-cd `b879ae2` (42+9 green; side-find: cd's committed openapi.yml
  says 1.0.0-SNAPSHOT vs pom release version — every test run dirties the tree, small
  separate fix), qits-gateway `1c7ca67` (89+5 green, variant untouched). All three on
  GitHub. **Fact learned: qits-dns is NOT on this local platform** — no bare on the git
  host, no container; its GitHub push is its whole sync (the plan's "ten processes"
  table counts it, but the local train runs 10 other containers incl. idp). Serial
  platform deploys re-running for cd → gateway only (handoff-dance, then a :8080 blip),
  strict per-repo run-status checks + live-log canary confirmation (first deployer
  attempt had weak failure handling and tripped on the missing dns repo — killed).
  **LC wave 2 DONE**: qits-stt `f1c20af` (9 green), qits-projects `9569717` (all four
  modules green), qits-artifacts `06e2226` (277 green). None pushed yet.
  **LC wave 3**: qits-ci DONE (`5b92f4a`, 131 green; the OTEL_SDK_DISABLED remark
  turned out to live elsewhere — only the shipped %dev/%test darkness exists there),
  qits-workspaces DONE (`f85c641`, six modules green), qits-observability DONE
  (`dbbf93b`, 76 green) — **LC IS CODE-COMPLETE, all nine producers normalized.**
  Self-export recursion guarantee verified in source, not assumed: Quarkus' log handler
  has NO re-entrancy guard (scope name only), so the guarantee is the app's — the whole
  receiver path (`OtelReceiverResource`/`TelemetryDecoder`/mapper) logs nothing, the
  only two loggers are the forwarder (DEBUG, below the INFO floor) and one latched
  store WARN; SDK export-failure diagnostics are throttled 5/min and fire only after a
  failure. Traces close the loop instead via `suppress-application-uris`.
  Pattern now confirmed in FOUR repos (cd, stt, projects, artifacts): committed
  openapi.yml version stamps lag the pom, so any test run dirties those trees — one
  platform-wide sweep commit would end it. Waves 2/3 next:
  projects+stt+artifacts, then ci+workspaces+observability(self-export care). Then LD
  deployment identity, LE daemons, LF live validation. Caution: never two native builds
  in parallel on this host.

- **CL — candidate listing: COMPLETE AND PROVEN LIVE 2026-08-05.** The KnownCiRepos
  compromise is lifted; bootstrap-by-rerun works. Both released through the train
  (artifacts `97925dd` deployed `25b2e8ac`, qits-ci `4fbb585` deployed `95ec2fb0`, daemon
  pin intact). **Acceptance met**: rerun of the pre-bootstrap
  `@qits/ui-components@2026.802.154237` event (`6621c680`) fired **all 8** listening SPA
  repos (was 1 before the swap), every run SUCCESS ending "already the pin - nothing to
  hop". Note evaluation latency: ~2 min between 202 and the first enqueue (a git fetch
  per candidate, ~35 candidates now) — expected, single trigger worker.
  Contract: `GET /artifacts/git` → `{"repositories":["<repoId>",...]}`.
  **CL-a DONE**: qits-artifacts `97925dd` on main (not pushed to GitHub; pushed to the
  platform host 2026-08-05, deploy in flight) — `GET /artifacts/git` →
  `{"repositories":[...]}` sorted, both backends: file provider reads the data dir (real
  layout is `<data-dir>/<repoId>/origin`), DFS selects distinct repositoryId from
  `git_pack` (a repo has a pack row from creation — HEAD symref/reftable). Enumeration
  failure is 500, never `[]`; ids slug-filtered in the route; empty host is two extra
  test classes (suite data dir is shared — "a process configuration is a class, not a
  case"). Verify green (service 275). Native NOT run — the pipeline's image build is the
  native gate.
  **CL-b DONE**: qits-ci `4fbb585` on main (not pushed) — `ListedAndKnownCiRepos`
  (ci/control, the bean the engine gets) unions `KnownCiRepos` (now `@DefaultBean`,
  injectable by concrete type; `@Mock` FakeCandidateRepos still outranks both) with a new
  `GitHostRepoListing` port; HTTP adapter in service/githost (2s connect / 3s request, 5s
  TTL on successful reads only, failures never cached). `file://` host = DEBUG, no socket;
  every real failure = WARN + fall back to known. Listing ids filtered through
  `CiIdentifiers`. 12 new unit tests + the production-gap case in CiManualTriggerTest (no
  run row, no bare cache, fires anyway). Verify green (service 124). Compromise prose
  replaced in CiCandidateRepos/AGENTS/README.
  Acceptance still pending live: rerun `SoftwareRelease` for
  `@qits/ui-components@2026.802.154237` fires all 8 listening SPA repos, not 1.
- Otherwise nothing running. Four commits from the 2026-08-04/05 session sit on their submodule mains,
  **none pushed**:
  - qits-ci `07ab2b0` — `CiRestartReconciliationIT` closes the last human-verified-only gap
    (boot reap + interrupted-run FAILED, docker + alpine:3 only, @Tag extended).
  - qits-ci `cf96e94` — **manual event-pipeline trigger**: `POST /ci/api/events/trigger`
    `{name, payload, occurredAt?, eventId?}` → 202 `{eventId}`. Omitted eventId = fresh UUID
    = rerun (dedupe constraint `unique(trigger_event_id, repo_id, config_path)` silently
    drops a replayed id); explicit eventId = opt-in idempotence. Feeds
    `CiEventTriggerService.Arrival`, async on ci-trigger-worker; domain events stay the
    primary trigger. Guarded by `MachineAuth.requireProject(ANY)` (`project=*` — a manual
    trigger names no repo), behind `qits.auth.machine.required`.
  - qits-workspaces `8b03e67` — `WorkspaceDto.createdAt` (`Instant`; the only "recently
    touched" sort key available today, documented as an approximation).
  - qits-spa-workspaces `48c942a` — **overview pre-PoC tree** replaces the picker on the
    root route: repos as roots (project label), per-repo fan-out with progressive render,
    branch↔workspace join by name, trunk excluded, workspace-less branches get "Create
    workspace" (`adoptExisting: true`, legacy slug rule with its 64-cap length bug fixed),
    sort by optional `createdAt`, no SSE. 491 tests green.

## Open items

1. **Push the backlog to GitHub**: the submodule mains above plus spa `9199e7d` and
   qits-workspaces `758d0a2`+`2392a66` (webui embeds) + root gitlink advance + this file.
   Platform git host has everything.
2. **RELEASES DONE 2026-08-05** (direct push door, `-o qits.token=local-dev`): spa `48c942a`
   CI green → workspaces `758d0a2` (createdAt + webui gitlink) deployed ACTIVE, served
   bundle verified to carry the tree components → qits-ci `cf96e94` deployed alone on a
   drained queue, container healthy, daemon pin intact (`2026.803.184200` adopted).
   Trigger endpoint proven live: 400 envelope on bad input; **401 anonymous → 403
   authenticated without `project=*` → 202 `{eventId}` with it**; smoke event matching no
   trigger file caused zero runs. Machine auth is ON live (`QITS_AUTH_MACHINE_REQUIRED=true`
   on qits-ci).
   **Tree page browser-verified by screenshot (playwright chromium, installed 2026-08-05)**,
   which caught a real bug: repo roots rendered raw UUIDs — the repositories API has no
   `name` field (platform repos are name-keyed by id, user repos UUID-keyed). Fixed same
   day: `repositoryLabel` derives from the clone-url tail, id fallback (spa `9199e7d`,
   embed `2392a66`, deployed ACTIVE, re-screenshot shows real names). Leftovers on the
   page, both honest: one probe repo has no readable url tail (UUID fallback), and the two
   inert rollout-probe repos both render as `drift-forge` (same url tail; they are
   deletable leftovers anyway).
   **Rerun proven on the real bootstrap case**: the `@qits/ui-components@2026.802.154237`
   npm SoftwareRelease predates this platform's event log; payload reconstructed from the
   git tag, POSTed → 202 eventId `d54a8646` → run `33f1bf53` SUCCESS ending
   "already the pin - nothing to hop" (idempotent by design). **Limit worth knowing: only
   1 of 8 listening SPA repos fired** — `KnownCiRepos` (run rows ∪ bare caches) excludes
   bootstrap-pre-seeded repos that never pushed, so reruns cannot reach them until each
   repo's first push. For bootstrap-by-rerun that candidate-list compromise is the
   blocker to lift first.
3. **Review WO-b's judgment calls**: the merge panel + "Landed from this screen" section
   left the root page (merging lives on the detail route now); create POST carries
   `repositoryId` in the body.
4. **qits-ci doc drift: DONE** (2026-08-05, `a6a1abc`, pushed everywhere): README/AGENTS
   rewritten against the shipped `MachineAuth` reality. Corrections beyond the ask: the
   auth classes live in `qits-integrations-quarkus/qits-auth-core` (never in this repo);
   the fail-open mode is now "a new write endpoint that omits the guard call", not path
   matching; the cd announcement uses `CdBearer` (`aud=qits-cd`), not "no token"; the only
   audience key is `qits.auth.machine.audience`.
5. **Restart-IT findings: DONE** (2026-08-05, qits-ci `006fc1d`, pushed everywhere,
   gitlink `0d973bd`): failed boot `docker ps` is a WARN naming runtime/exit/stderr tail
   (tested with a real failing script, not a stub); StartupEvent observers ordered
   **reap (2000) before sweep (2100)** via `@Priority` — load-bearing, not cosmetic:
   sweep-first restarts interrupted runs whose brand-new containers the reap could then
   `rm -f` (same label, indistinguishable). `BootReconciliationOrderTest` pins ArC's
   resolution order = notification order. "One qits-ci per docker daemon" documented in
   reapOrphans javadoc + AGENTS + README deploy section. Verify green (service 128).

## User decisions this session (supersede workspace-overview-ux.md's open questions)

Mental model: project → epic → workspace tree; epics get workspaces per repository; only
merge-to-main orchestration is in scope today; project and epic become separate views later.
Pre-PoC scope shipped as WO-b: cross-project tree, repositories as roots, legacy `../qits`
overview as basis, branches without workspaces must be creatable (they arrive remotely),
default sort most-recently-touched.

## Deferred / gated backlog

- **BK — daemon GC strategy**: gated on the artifacts GC substrate; artifacts-gc-plan.md has
  four ⚖ decisions the user has not answered. Pin surface it needs (`GET /ci/api/daemon`
  with `previousDaemonVersion`) is live.
- **Git-storage flip**: DECISION PENDING (git-host-storage-unification-plan.md). Cold-wipe
  experiment is a scoped NO-GO; proposed order AZ (lifecycle routes) → AT-projects →
  AX-remainder → AY → flip. Cheap proof available: second qits-artifacts on a spare port
  with `QITS_REPOSITORIES_GIT_STORAGE=dfs`, import one real history, three checks.
- **BI remnant**: one rowless daemon blob (`fbefa249…`) keeps `orphanBytes` non-zero; never
  recurs (bootstraps publish with identity now). Adopt or ignore until GC.
- **OTLP exporter warns per export** when qits-observability is absent;
  `OTEL_SDK_DISABLED=true` is the escape hatch. application-log-streaming-plan.md is
  written, unblocked, not started.
- **Three REJECTED ladder rows** (`2026.803.91607`, `2026.803.174754`) are terminal by
  design — defect-era verdicts, not bad releases.

## Standing facts and landmines (not in memory files)

- **Minting a machine token on this platform**: idp clients are env-provisioned on the
  qits-idp container (`QITS_IDP_CLIENT_<NAME>_SECRET`, `..._CLAIMS_PROJECT`); only
  `qits-artifacts` carries `project=*`. Mint on qits-net:
  `POST http://qits-idp:8080/idp/token` with client basic auth,
  `grant_type=client_credentials&audience=<service>`. The manual CI trigger needs exactly
  that `project=*` token. There is no clients admin API deployed (404) — contract doc's
  `/idp/api/clients` is aspirational.

- **Release a self-hosting repo only after its epic build drained the queue** — a release
  run's npm install can race the redeploy of the service building it.
- Security model: publish surfaces are tokenless on qits-net by decision; qits-idp gates
  them all together when it lands. `DaemonOpenPublishTest` and siblings pin this — re-gating
  one surface alone fails the build.
- idp token endpoint is not reachable via gateway; call it on `qits-net`.
- Git storage: the DFS/blob engine ships in qits-artifacts but is inert
  (`qits.repositories.git.storage=file`); the volume (31 bares) is the real storage.
- musl builder supply-chain flag stands: `FROM localhost:8081/...` + toolchain fetched from
  `more.musl.cc` per build.
- qits-ci: a record targeted by a MapStruct mapper needs `clean` after changing — the stale
  generated impl otherwise fails with `NoSuchMethodError`. Same family: a non-clean verify
  after a source deletion fails on stale `target/` classes.
- qits-artifacts: every build rewrites `docs/openapi.yml` `info.version`; the churn keeps
  reappearing until someone commits it (qits-ci's copy was committed with `cf96e94`).

## Preserve

- Root untracked user files: `daemon-artifact-identity-plan.md`, `workspace-overview-ux.md`.
- `services/qits-workspaces/.claude/` is user-owned and untracked.
- Do not reintroduce EventStream as a CI/Workspaces submodule or reactor module.
- QuarkusTest on this host: pass `-Dquarkus.http.test-port=0` (8081 is the npm registry).
- Moving the daemon pin stays a human act: edit cd run-args volume + compose, restart
  qits-cd, then redeploy qits-ci — in that order (qits-cd caches run-args at boot).
