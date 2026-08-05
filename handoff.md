# Handoff

Updated 2026-08-05. The ci-daemon objective (artifact identity, release-train publish,
auto-adoption) is met and proven live; its workstreams, decisions and rollout history were
removed from this file. History is in git.

## In flight right now

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
  Named follow-ups: expose resource identity in the logs DTO; qits-ci success-path
  daemon-tail capture (has per-step cost, decide first).
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
