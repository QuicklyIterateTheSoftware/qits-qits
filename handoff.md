# Handoff

## Full rebootstrap green 2026-08-13 (~17:30)

`unwrap --with-data-volumes` + `QITS_SHIP_MAINS=1` boot: exit 0, 69 ok + 1 skip
in 19m51s, 17/17 services healthy, edge 200, zero fails/warns, every deployed
sha = local main, all 24 CI repos green. Pre-wipe sync rescued two things that
lived only on the platform githost: qits-spa-deployments main (fast-forwarded
home — the "three outcomes" commit) and the wrapper branch
`refining/give-the-platform-a-status-page` (fetched into the local checkout).
The githost held zero tags; 16 repos' mains are ahead of their newest release
tag (deployments by 15 — the swarm migration), so a restore boot stays wrong
until a release wave runs through the fresh platform.

Updated 2026-08-11 evening. Everything shipped-and-verified has been removed;
history is in git. What remains is open, pending, or standing. This is the ONE
handoff document — handover.md (the userflow plan) is folded in below and deleted.

## Session close 2026-08-11 ~20:15 — where to pick up

- **Platform state: healthy and current.** 16 containers green, edge 200,
  everything released tonight is deployed (see the DB PATIENCE entry below
  for the nine versions). No builds in flight, no red runs EXCEPT
  qits-events' release-recipe run for 171736 (fix committed, `7b23dba`,
  rides its next release — the deploy itself was green).
- **NOTHING from today is on GitHub.** Every commit sits on local submodule
  mains and on the platform git host only — including the superproject's own
  commits (docs `784dfac`/`c1d7da9`/`80a1ac3`, scm-plan removal `228defb`).
  The byte-plane split itself is STILL not on GitHub either. A backup push
  sweep (superproject + all touched submodules) is the biggest un-done
  hygiene item. Uncommitted in the superproject working tree: handoff.md
  (this file) and the untracked plan docs (db-patience-plan.md,
  container-orchestration-plan.md, .env, .claude/ — same set as before).
- **A second session is running the container-orchestration campaign** (top
  entry) and edits this file too — merge, don't clobber.
- **Next-step candidates, in rough value order:** (1) the GitHub backup
  sweep; (2) live cutover chaos proof — either the next rebootstrap or a
  cheap targeted one: `docker stop -t0` the platform postgres for ~10s
  under a push + a few API calls, everything should hold (that would close
  db-patience-plan.md's last big open item); (3) an ordinary qits-events
  release to green its release recipe; (4) the deferred byte-plane items in
  the REBOOTSTRAP entry (blobstore/registries calver releases + consumer
  bumps, remaining `--network qits-net` build conversions, dockerd
  registry-mirrors + git-remote host steps, mirror admin UI, spa-artifacts
  key rename).
- Today's memory files are current (db-patience, wrapper-push-keeps-catalog,
  scm-domain-events, byte-plane campaign); trust MEMORY.md's index.

## In flight right now

- **BOOTSTRAP REPLAY CAMPAIGN (2026-08-12 afternoon/evening): restore
  semantics designed, implemented, partially proven.** Design + state ledger:
  `bootstrap-replay-plan.md` (root). The user's dictated model: a bootstrap
  RESTORES the last-released state; replays must stop impersonating releases.
  Landed on local mains (all unpushed): WP1a — seven publisher recipes on
  `event: SCMPublishTag` (version from `tagName`, `when: repoId`); WP1b —
  cli-bootstrap `28c4e77` deletes the synthetic SCMRelease (replay = tag push
  + run wait; up-to-date tag SKIPS); WP2 — qits-ci `f505119` durable
  (repository, version) join: `SoftwareRelease` fires only when a green
  publish run AND a real `SCMRelease` both exist (replays silent forever;
  tag runs read `tagName`); WP3 — cli-bootstrap `669aad2` **RESTORE IS THE
  BOOT'S DEFAULT NOW** (deploy ref = newest CalVer tag; `--ship-mains` /
  `QITS_SHIP_MAINS` is the dev loop's new spelling — A PLAIN RERUN
  DOWNGRADES A DEV-LOOP MACHINE TO ITS LAST RELEASE, say --ship-mains when
  you mean mains). WP4 — the eight stuck SPA maintenance branches released
  and every red run healed: 32/32 repos SUCCESS, zero maintenance branches;
  lesson minted: NEVER rewind-replay a `maintenance/*` ref (parent build
  races the release step and deletes the branch) — heal bump branches via
  the release endpoint. Root cause of those red tiles (measured): train bump
  runs fire off replays while qits-workspaces doesn't exist yet (not a seed
  service, deployed minutes later); one-shot fetch, nothing replays it.
  **TAGS ARE LOAD-BEARING STATE NOW** (plan doc section): stamps die with
  every data-wiped githost; 7 deployables had no local tag, 6 stale
  (pre-db-patience!). Tag-sync done for today's 2026.812.* releases; the
  GitHub backup sweep must push --tags. IN FLIGHT: the fleet release wave
  (all 17 deployables released off current mains — oci-postgresql alone,
  deployments late, ci LAST AND ALONE — then local tag-sync + main
  fast-forward), subagent running. **STAGE A PROVEN (2026-08-12 ~17:10): the
  ship-mains rebootstrap on the new code went green** — exit 0, 69 ok + 1
  skip, 27m35s, 17 healthy, edge 200; all SEVEN publisher replays ran as
  SCMPublishTag-triggered release runs (SUCCESS); ZERO SoftwareRelease events
  on the bus (the WP2 join, live in deployed ci c275f43, kept every replay
  silent); ZERO maintenance bump runs, zero red tiles, zero 401s. The
  original red-tile class is structurally gone. The wave-blocking discovery
  stands recorded: qits-workspaces has NO door to release a main with
  nothing to merge (branch=main → 400 by design, branch-at-tip → 409;
  WorkspaceService.releaseBranch:1482 / ReleaseIntegrator:411), and the
  2026-08-11 release lineage is UNRECOVERABLE (stamp commits were never
  pulled home before the wipes). User-directed staged path: (A) mains boot ✔;
  (B) release the ten tagless deployables through the normal door, each
  carrying real recorded debt (docs/deployments get their missing
  ci-event-release.yml; the other eight get the :$version image-tag wart
  fix), then sync tags+mains home AND push the 17 to GitHub — in flight;
  (C) the first restore-default proving boot. **CAMPAIGN CLOSED
  (2026-08-12 night): third restore boot ZERO WARNS** — exit 0, 69 ok + 1
  warm skip, 14m32s, 17/17 healthy, edge 200, pure-restore event log. Three
  iterations, each fixing one measured class: (C1) migration-delta — ci's
  main-built seed applied V3, the tag-built V2 successor refused it;
  salvaged live (DB surgery + deployer manual door), fixed at source by
  one-identity-per-boot (cli bd4215b) and ci's release 2026.812.184140
  (V3 + the join + calver pins; earlier stamp .183516 BURNED on stale
  1.0.0-SNAPSHOT pins the docker cache had masked — projects had the same
  landmine, defused via .192419; artifacts/githost still pin blobstore/
  registries snapshots with NO calver to bump to — the standing byte-plane
  item, sharper now). (C2) qits-oci detached at its stale tag built
  maven-base without the `build` user — identity-by-tag now scoped to
  DEPLOYABLES ∪ RELEASE_PUBLISHERS (cli 6103c72, final main). (C3) green.
  Ledger: bootstrap-replay-plan.md. Memories: restore-default-boot,
  release-stamps-burn. All touched mains+tags on GitHub. Swarm session got
  its green ping + shas; daemon handed over 2026-08-12 night. New findings
  parked: AgentTunnelProxyTest holds an untimed HttpClient.send (can wedge
  verify forever); qits-events' release yml still carries the rmi wart;
  VOLUMES-KEPT re-bootstrap landmines, both owned by the swarm campaign's
  record (swarm-campaign.md in the swarm worktree): (a) rotated seed-role
  passwords — FIXED durably (the CLI's postgres phase seeds from
  pd_resource rows once the server answers); NEVER hand-edit pd_resource
  (a manual edit armed a rotation storm — post-mortem in the campaign
  file; the earlier "ALTER roles + clear rows" interim recipe is
  WITHDRAWN). (b) the row hole: kept ACTIVE deployment rows + unwrapped
  services + unchanged mains → tip-ordering drops the replays and an app
  can stay seed-served; salvage = forced env/dev back-one-with-no-ci then
  forward push (fresh build time beats the tip). Top backlog item.
  PLATFORM IS SWARM-ONLY since 2026-08-13: docker driver deleted
  (deployments 392c8b2, orchestrator key = boot guard), final boot 70/70
  in 14m16s, forced-rollback proof 36/36 edge probes at 200. Coordination: the
  swarm-migration session (worktree qits-qits-swarm) holds off the docker
  daemon until stage C is signalled done; it will pass QITS_SHIP_MAINS=1 for
  its own proofs; its qits-deployments b1058ae (deploy-lifecycle events,
  on main) shipped with stage A. Ci-merge note: local qits-ci main is
  c275f43 (githost release history merged INTO local main, no conflicts,
  webui gitlink at the released 104d843; all 8 SPA mains ff'd + pushed to
  GitHub with today's tags — that unblocked the boot's webui fetches).

- **GITHOST + MIRROR GOT FRONTENDS (2026-08-11): both split services serve a
  SPA now — ALL LOCAL; ships with the next rebootstrap (or a coordinated
  gateway+cli release).** New repos, both on GitHub main: `qits-spa-githost`
  (`bf69c6a`) and `qits-platform-spa-mirror` (`4d90de8`) — Angular 21.2,
  `@qits/ui-components` 2026.807.122825, QitsMainLayout + provideQitsNavigation,
  submoduled twice each (wrapper `99a34b5`; backend webui gitlinks). Segments:
  the githost UI lives at `/githost` (SPA + `/githost/api` + `/githost/q`) and
  the wire protocol stays at `/git` as an extra prefix — gateway `a382701`
  (`GITHOST("Githost", 9, "/git")`, `MIRROR("Mirror", 10)`); cli-bootstrap
  `47a0472` renames proxy-hosts key `git`→`githost`, adds `mirror`, moves the
  githost health poll to `/githost/q/health/ready`. **Gateway and cli commits
  must ship together** — the old key is a gateway startup error and vice versa
  (bootstrap ships local mains, so a rebootstrap satisfies this by itself).
  Backends: qits-githost `77090be` (Quinoa 2.8.2, `GET /githost/api/repositories`
  with failed-read-is-500, non-app root `/git/q`→`/githost/q`, 85 tests green,
  packaged bundle proven at `/githost/` with the right base href); qits-platform-
  mirror `3ad7ee1` (Quinoa, `/mirror/api/repositories` + `/upstreams`, 52 tests
  green, and the FULL packaged-surface probe list measured against a throwaway
  postgres — deep links fall back, mistyped api and protocol paths all 404).
  This closes byte-plane-split orphan (1), the mirror admin API + explorer UI.
  Doctrine correction that came out of it (docs/project-setup-quinoa-angular.md):
  Quinoa's SPA fallback mounts at `/<segment>/*` only and ignore entries are
  ui-root-relative (read from 2.8.2 sources, then measured on the mirror) —
  artifacts' `/v2` entry is really the `/artifacts/v2` misroute guard; the
  doc's stale artifacts row fixed, githost + mirror rows added. UNPROVEN:
  native + image builds for both backends and the CI-recipe webui halves
  (transcribed from artifacts' working pipelines); githost packaged-surface
  probes (needs the DB env triple — rides the bootstrap). Wrapper pushed to the
  platform githost after this commit (catalog rule) so the reconcile adopts
  both SPA repos by name.
  **RELEASED AND LIVE the same evening:** qits-githost `2026.811.185221`,
  qits-platform-mirror `2026.811.185649`, qits-gateway `2026.811.190126` —
  in that order, with the deployer's gateway run-args edited between mirror
  and gateway (`PROXY_HOSTS_GIT`→`GITHOST`, new `MIRROR=qits-platform-mirror`;
  config-volume sed as root + deployer restart, CI idle). Nav carries Githost
  + Mirror, `/githost/` and `/mirror/` verified in the browser through the
  edge (screenshots `githost-live.png` / `mirror-live.png`, repo root),
  `/git` protocol intact, githost packaged-surface probes all green on the
  DEPLOYED container. The unproven list above is now proven except the two
  repos' CI webui halves on the RELEASE pipelines (post-receive halves ran
  green in these releases).
  **One red run, root-caused:** the gateway's environment/dev build failed at
  the runtime stage — `Using cache` found intermediate `7aaba39`, seconds
  later `failed to export image: No such image`. Not any GC of ours (docker
  events show ZERO image deletions in the window). Mechanism: this host's
  3-day-old native dockerd runs the **containerd image store**
  (`io.containerd.snapshotter.v1`), where legacy-builder cache intermediates
  are content under leases, collected by containerd's own GC (invisible to
  docker events) once unreferenced — and a release runs TWO concurrent
  legacy-builder builds of the same Dockerfile (main variant=local +
  environment/dev variant=oauth) sharing the early cache chain; the main
  build finishing (its pipeline even ends `docker rmi "$ref"`) released the
  shared intermediate mid-export. Recovered by the rewind-replay on
  environment/dev — which in the SCM-events world fires a build for BOTH
  pushes (the rewind sha built too; harmless, same image).
  **Rebootstrap-readiness audited (same night): one boot-blocker found and
  fixed.** cli-bootstrap `65eeb46` (231 green): the seed never npm-builds a
  SPA — it writes a placeholder index.html at an enumerated `seedUiPath`,
  and githost/platform-mirror were recorded there as "no client", so a cold
  boot would die at the new Dockerfiles' `test -f` in phases 9/11 of 67,
  before any native compile. Both repos joined `SEEDED_REPOS` +
  `seedUiPath` (webui dist paths verified against the real trees);
  sources()/git-repo/preseed derive from the same lists (39 repos now).
  Seed webui submodule init was already generic (`submodulesShallow`). The
  SPA repos are deliberately NOT in `RELEASE_PUBLISHERS` or the deploy
  train, pinned by a new test. Proof rides the next rebootstrap.
  **Gateway pipelines converted to buildkit (`f9c1f12`, rides the next
  release automatically):** measured first — NO CI build on this platform
  ran buildkit before (node-docker-base ships no buildx; `DOCKER_BUILDKIT=1`
  alone hard-errors "buildx component missing"), and both racing gateway
  builds were `QITS_VARIANT=local` (env/dev carried an older .config
  snapshot — identical cache chain, a tighter race than first written up
  here; self-heals at the next release, which advances env/dev's .config).
  Both pipeline files now carry a prelude proven from the real step image
  against this daemon: install `docker-cli-buildx` if absent,
  `DOCKER_BUILDKIT=1`, `BUILDX_NO_DEFAULT_ATTESTATIONS=1` (keeps the export
  a single manifest — the platform's first buildkit push against its own
  registry should not change artifact shape unverified). The trailing
  `docker rmi "$ref"` is DROPPED in both halves — it was the
  reference-release in the race and freed nothing. Fleet path, deliberately
  NOT taken unilaterally: adding docker-cli-buildx to
  images/qits-oci/node-docker-base flips eight repos' builds to buildkit
  implicitly (the CLI auto-uses buildx once present) — that is a train
  decision; until then every other repo stays on the legacy builder.
  CORRECTION to the rebootstrap entry below: githost's and mirror's step
  image is node-docker-base, NOT ci-base — their fix class 6 works because
  `--network host` is legal on the legacy builder too; buildkit was never
  actually involved anywhere in CI until `f9c1f12`.
  **qits-net→host doctrine sweep COMPLETE (same night, user go-ahead):**
  artifacts `33be1ef`, ci `9bf9b88`, workspaces `00da24c`, projects
  `b0731b9` — both pipeline files each, identical diff (`--network host` +
  `http://$QITS_REGISTRY/artifacts/maven/maven` build-arg), the four
  qits-net prose blocks rewritten honestly, bash -n clean. Full-tree
  classification: NO `--network qits-net` docker build remains, no RUN
  dials a wire alias anywhere, every other build's verdict under buildkit
  is fine (gateway/stt/edge/observability/docs/daemons/images all default
  networking or host). node-docker-base now ships buildx (images/qits-oci
  `f95611e`) — INERT until the image ships: the next rebootstrap builds it
  from source, or a qits-oci release + host pull/retag of the bare local
  tag (that starts the image train — deliberate trigger, NOT taken
  tonight). The gateway pipelines' apk-install prelude becomes a no-op
  once it ships. This closes the standing "remaining --network qits-net
  builds" item in code; proof is each repo's next build on the new image.

- **CONTAINER ORCHESTRATION CAMPAIGN STARTED (2026-08-11): building
  `services/qits-containers`.** Plan approved and tracked in
  `container-orchestration-plan.md` (rewritten to the refined state — decisions,
  one-page design, WP table). Round 1 = new repo (core lib + service + client
  lib) + qits-ci hard cutover. Headline requirement: the service's own restart
  never invalidates running containers (adopt-on-boot, row-before-run,
  rows-only observer — the qits-deployments model generalized; policies
  EPHEMERAL/IDLE_STOP/EXPLICIT). User decisions: qits-ci first adopter;
  service owns lifecycle AND data plane (proxy ships flag-off in round 1).
  **WP1-7 DONE (same day): the repo is BUILT and WIRED** — 160 JVM tests + 5
  ITs green, GitHub main current
  (`https://github.com/QuicklyIterateTheSoftware/qits-containers.git`,
  2df567c), submodule added to the wrapper per the ritual (name
  qits-containers, gitdir absorbed). Highlights: restart ADOPTION PROVEN on
  real docker 29.7.2 (ContainersRestartAdoptionIT — Id/StartedAt unchanged,
  unlabelled bystander survives); causation stamp measured firing despite the
  augmentation PU warning; docker 29.x combined-inspect needs
  `index .State "Health"` on the raw-JSON path (pinned in tests); tunnel
  contract requires a per-tunnel secret (the sources' path-param impersonation
  weakness deliberately not reproduced); the release pipeline is the
  platform's FIRST dual maven+docker publisher (two steps — no build image
  carries JDK+docker; artifact spelled `qits/qits-containers`).
  **ALL NINE CODE PACKAGES DONE (same day).** WP8: cli-bootstrap `b3262e3` —
  containers is a core seed service (dns precedent), seed maven publish
  extended to `-pl core,client` (step-container builds have no host .m2),
  receive-only idp audience like the deployer, cold plan 70 phases, 232
  tests. WP9: qits-ci `ae9d779` (425 tests) — CiDaemonLauncher builds specs
  and calls the client, CiProcess DELETED, boot reap = owner-scoped
  destroyAllOwned(createdBefore) with PT60S patience, owner =
  `${quarkus.oidc-client.client-id:qits-ci}`, ref = the container name,
  ContainersWireReflection added for the native binary; cli-bootstrap
  `407e2e5` (233 tests) — QITS_CONTAINERS_URL into ci's block + run-args,
  oidc audience repointed deployments→containers, **ci's docker socket mount
  and --group-add REMOVED**, read-shaped orchestrator warm probe. Wrapper
  `8b308f0` (gitlink + plan doc + handoff) is PUSHED to GitHub — today's
  wrapper commits are backed up now; submodule contents still are not
  (except qits-containers, fully pushed).
  **THE PROVING REBOOTSTRAP IS GREEN AND THE RESTART PROOF IS LIVE
  (2026-08-12 morning): attempt 11 exit 0, 70/70 (1 warm skip), ZERO warns,
  ~14m, 17 qits-pd containers, edge 200 — every CI step of the whole train
  ran through orchestrator-spawned containers, and the live proof followed:
  a workload created over machine-token REST survived a `docker restart` of
  the deployed orchestrator byte-identically (Id/StartedAt unchanged), was
  re-answered RUNNING from the durable registry, served logs, deleted
  clean.** The run also proved tonight's other-session work (githost+mirror
  SPAs, gateway/cli rename pair, nine db-patience releases through the
  postgres-cutover window). Eleven attempts; every failure fixed at source
  with a regression net: (1) unwrap erases unsynced release stamps →
  restamp + tags + memory; (2) lib-seed order in BOTH seed lists +
  last-entry sentinel → dependency-true, test-pinned; (3) native
  reflection: SpecFingerprint family + Response-entity-only ErrorBody →
  holders + coverage-walk test; (4) Central throttling from cold caches →
  persistent qits-maven-cache (cache-class in unwrap, qits group purged per
  run); (5) main-head release scripts vs old-tag trees → presence guard;
  (6) qits-spa-artifacts rename half-landed → .gitmodules relative URL +
  derived pipeline URLs + an upstream trigger that had NEVER fired since
  the rename; (7) THE STEP-SANDBOX LAW: cap-drop=ALL forbids in-container
  user switching (no CAP_CHOWN/SETUID even for root) → step decl gains
  `user:` (refused with docker:true), maven-base ships passwd-backed
  `build` + /workspace at 1777 + system safe.directory (root lost
  DAC_OVERRIDE too — three lessons, one directory); (8) idp-cutover 401
  window at the orchestrator → launches/reaps hold through auth blips
  (PT90S; safe because ensure is an idempotent PUT). FOLLOW-UPS:
  **the idp-401 root cause is SETTLED (2026-08-12 afternoon), and the old
  "keys rotate on redeploy" line was WRONG** — measured live: one ACTIVE
  row in qits_platform_idp, minted by the SEED idp at 07:01:52, kept
  byte-identical by the deployed successor (started 07:05:47); the idp
  has persisted its key since `194832a` (2026-08-01), so an ordinary
  redeploy rotates nothing. The remaining exposure was a REAL rotation
  (operator action, or an idp landing on an empty database) overlapping
  an idp blip: `quarkus.oidc.token.forced-jwk-refresh-interval` defaults
  to 10M, so one failed refresh costs ten minutes of 401s per validator.
  Now PT5S in all five validators — artifacts `7f0753f`, ci `aa6791d`,
  containers `85d1c9e`, deployments `84c488e`, gateway `c21ca3e` (the
  gateway also gained the `connection-delay=30S` the other four already
  carried) — **PROVEN LIVE by a same-day rebootstrap** (unwrap
  --with-data-volumes + one call: exit 0, 69 ok + 1 skip, 30m25s, 17
  healthy, edge 200, ZERO 401s anywhere in the run — the idp cutover
  passed clean). All five deployed images are tagged with exactly these
  five shas; zero unrecognized-key lines in their boot logs; the ci
  native binary carries the key and `PT5S` (strings on the deployed
  binary); and a behavioral probe pinned the runtime value: with idp
  stopped, two unknown-kid probes 6s apart EACH burned the 10s JWKS
  connect timeout (a second attempt is impossible under the old 10M
  default) while a third probe 2s later answered in 3ms (the 5s floor,
  clocked from the last attempt's end). The fresh boot also re-proved
  no-rotation: one ACTIVE key row, seed-minted 13:52:07, kept by the
  deployed idp.
  Deliberately NOT shipped via qits-auth-core: measured, a
  `quarkus.oidc.*` key in the lib's shared fragment is an "Unrecognized
  configuration key" boot WARN in every non-oidc consumer
  (qits-platform-mirror today); the fragment now says so (`61e7130`) and
  the pattern lives in docs/project-setup-quinoa-angular.md's new
  "machine-token validation baseline" section (wrapper `8bf6ee5`).
  Residual, recorded there too: a JWKS refresh that fails while idp is
  down still answers a plain 401, indistinguishable from a bad token —
  critical machine callers hold through it briefly (qits-ci's PT90S is
  the worked example). Side note: services/qits-deployments has an
  uncommitted regenerated docs/openapi.yml (version stamp churn from a
  test run, not part of any change). Still open: GitHub backup sweep for
  most submodule mains (measured 2026-08-12: 31 submodules, ~213
  local-only commits; fetch --tags from the platform githost before
  pushing so release stamps ride along); round 2 = workspaces/projects
  onto the orchestrator + proxy adoption (flag-off skeleton in,
  per-tunnel-secret contract).
  **CAMPAIGN CLOSED — MIGRATION VERIFIED AND RESIDUE SWEPT (2026-08-13).**
  A repo-wide audit confirmed production code fully migrated: only
  qits-containers and qits-deployments touch docker (both hold the socket by
  design, deployments swarm-only behind its boot guard); workspaces, projects
  and ci compose no docker argv and spawn no docker process. The audit found
  only doc/image residue, cleaned in four commits on local mains (unpushed,
  ride the next releases): workspaces `a603532` (docker-ce-cli out of the
  image, DockerExecutor prose rewritten — qits-containers pulls the pin via
  the ensure spec now, bound `qits.containers.client.ensure-timeout`; process
  segment `docker-run` renamed `container`, 31 affected tests green); projects
  `644c47f` (docker-ce-cli out, DockerAgentRuntime/socket prose replaced);
  ci `d28bc29` (docker CLI install removed entirely — ci spawns nothing);
  cli-bootstrap `81ff9ef` (contradicting socket paragraph in the projects
  extras deleted, socket-group javadoc names deployer+orchestrator only,
  ComposeTemplateTest 31 green). `container-orchestration-plan.md` REMOVED at
  user direction (this wrapper commit); the two still-open items — proxy
  adoption and the first real workspace/agent smoke — stay tracked in the
  campaign memory, not in a doc.

- **DB PATIENCE: SHIPPED FLEET-WIDE AND LIVE (2026-08-11).** Every postgres
  service runs PatientPgDriver (requests HELD at connection-open through a
  <15s outage, reads and writes alike), the DatasourceBaselineRules build
  enforcement, DbRetry read seams and inNewTx write seams — deployed to the
  dev platform through nine releases tonight: events 2026.811.171736, dns
  .172356, idp .172659, mirror .173447, githost .173728, projects .174012,
  workspaces .175121, deployments .175636, ci .180123 (last and alone,
  nothing eaten). All 16 containers healthy, edge 200. Libs released:
  qits-integrations-quarkus 2026.811.152803 + .165001, qits-eventstream
  2026.811.155429. The causation-sweep commits (workspaces/deployments/
  projects, V2 migrations applied at boot) and the SCM tag versionsort
  dedupe shipped WITH these releases — the old post-rebootstrap release
  queue is DONE. Doctrine + measurements: the guide's datasource resilience
  baseline (docs/project-setup-quinoa-angular.md) and the lib README;
  per-repo rules in each AGENTS.md. Plan doc REMOVED 2026-08-13 after a
  four-subagent code verification confirmed every work package (lib core,
  fleet config, read seams, inNewTx ledger) against the trees. Merge note: workspaces/ci pom
  conflicts against platform train bumps were resolved by merging platform
  main into local main before re-releasing (deployments merged clean).
  Open:
  - Live cutover chaos proof: DONE 2026-08-12 — green rebootstrap through
    the postgres window (see the replay-campaign entry).
  - qits-events' RELEASE-recipe run for 171736 is red (its release docker
    build lacked the host-network maven doctrine; fixed at source `7b23dba`,
    rides its next release — the deploy itself was green). dns got the full
    image-build wiring (`8b5765e`) BEFORE its release and shipped green.
  - Wave-2 remnant: the mirror libs' registry require*/resolve* reads ride
    blobstore/registries' calver releases.
  - inNewTx residue by design: a non-idempotent write failing inside the
    commit ack errors honestly; TM-reported failures never retry (Narayana's
    RollbackException is ambiguous — measured, in the lib README).
  - Lib README still carries the stale PatientPgDriver native watch item
    (native is PROVEN live); drop on next touch.
  - db-patience-plan.md removed 2026-08-13 (implementation fully verified).
    11 comment references across githost/ci/workspaces/projects/
    integrations-quarkus still name it — re-point them to the guide on the
    next touch of each repo, like the lib README's stale native watch item.
  - The five-repo eventstream-block restatement residue is GONE: all five
    dropped it in "Take the eventstream release" commits (workspaces
    524cc50, projects 0a6f80d, deployments cb5bbba, ci 1645475, githost
    b6c5eb3). Zero eventstream datasource lines outside the lib.
  - Step containers run as ROOT and zonky initdb refuses root: eventstream's
    CI verify su's to a build user (`7b50cad`); the lib's wire tests
    @EnabledIf-skip as root (classifier units still run).

- **PROJECTS CATALOG HEALED; THE WRAPPER ON THE GITHOST IS POST-SPLIT NOW
  (2026-08-11 evening).** Found while releasing: the githost's qits-qits
  main was PRE-SPLIT (`9df0a41` — the bootstrap seeds the wrapper from its
  GitHub state and the split was never pushed to GitHub), so qits-projects'
  self-seed had built a pre-split catalog and the release endpoint knew
  neither qits-githost nor qits-platform-mirror ("Repository not found").
  Fixed: local wrapper main fast-forwarded to the githost
  (`9df0a41..80a1ac3`, quiet push), projects restarted → the reconcile
  ADOPTED all 8 split repos by name and deregistered the stale pre-split
  rows (deregisterRow is the light path — githost repositories untouched).
  40 rows, catalog matches the split. Standing rule this implies: after any
  wrapper-shape change, push the wrapper to the platform git host too, or
  the catalog drifts.

- **REBOOTSTRAP CAMPAIGN CONTINUED (2026-08-11, session live).** Attempt 7 was
  aborted with the session; the host rebooted overnight and docker auto-started
  its partial stack. Today: `unwrap --with-data-volumes` (config kept) + one
  bootstrap. Attempt 8 reached phase 52/67 and taught two lessons, both fixed
  at the source:
  1. **The deployer never deployed anything** — its shipped default
     `qits.platform.deployments.git-host-url` still names the pre-split
     `qits-platform-artifacts:8080/artifacts`, nothing overrode it, and every
     spec read timed out. The BuildSuccessful was consumed (watermark advanced)
     and dropped, so no replay came for free; recovered live by adding the
     property to the deployer's config volume + restart + a manual-door replay
     (202, machine token via dev-qits-ci client). Durable fix: the CLI's
     run-args template now carries
     `qits.platform.deployments.git-host-url=http://<env>-qits-githost:8080`
     (cli `2d65770`, 226 tests green) — the run-args file IS the deployer's
     config file, seed and successors both read it at boot.
  2. **The githost answered 404 for a repository that exists** — phase 51's
     qits-oci-postgresql cutover severed every pool, and one second later
     phase 52's push hit `DfsGitRepositoryProvider.open`, which swallowed the
     JDBCConnectionException at DEBUG and returned null = 404. Fixed both
     sides: githost `fe26a6c` (a failed catalog read throws → 500, null only
     for cleanly-absent, 104 tests) and cli `d438ce2` (every githost push
     retries through Waiter, 5s × 90s, token masked once in `Boot.push`,
     230 tests).
  A converging rerun (attempt 9, 15m08s, exit 1) scouted phases 52-67 and
  flushed the remaining classes, all fixed on local mains:
  3. **Five repos' pipelines spelled the retired
     `qits-platform-artifacts:8080` maven build-arg** (workspaces measured:
     `Name or service not known`; githost/artifacts/ci/mirror identical).
     Now `--build-arg QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL"`
     in both pipeline files each: workspaces `0400b3c`, githost `e13154d`,
     artifacts `f1707f2`, ci `6958dc4`, mirror `77cc36a`.
  4. **qits-projects' image build was never wired for platform-maven deps**
     (the causation commit added the first ones; pom default localhost:8081
     is refused inside a docker build). `509e04a`: Dockerfile ARG/ENV +
     `-Dqits.maven.repository.url`, NEW `.qits-maven-settings.xml` (exact-id
     mirror — maven's default HTTP blocker exempts only localhost, so the
     build-arg alone would just move the failure), both pipelines build with
     `--network qits-net` + derived build-arg.
  5. **qits-docs' webui gitlink sat before the SPA's own rename** (spa built
     `dist/qits-platform-spa-docs`, guard wants `dist/qits-spa-docs/browser`).
     qits-docs `a57b187` advances the gitlink to `ae9f432`; the agent also
     repaired the submodule plumbing left broken by the repo rename. NOTE:
     qits-spa-docs local main is 2 ahead of GitHub — fine for the bootstrap
     (githost gets local mains), watch it if a source clone ever fetches that
     submodule from GitHub (the qits-spa-artifacts precedent).
  Proof run 1 (fresh volumes) then proved fixes 1-5 live — phases 50-59 all
  green including the postgres-cutover window — and flushed three more:
  6. **buildkit refuses `--network qits-net`** — mirror and githost step on
     ci-base, whose docker CLI carries buildx, so their builds never ran on
     the split topology (node-docker-base repos fall back to the legacy
     builder, which is why the same flag passes there). Both moved to the
     deployments-doctrine pattern (`--network host` + build-arg derived
     from $QITS_REGISTRY): mirror `e087f25`, githost `f5ae4bb`.
  7. **qits-artifacts pushed its image under the pre-split name**
     (`qits/qits-platform-artifacts:<sha>`) while the deployer resolves
     `qits/qits-artifacts:<sha>` — every deploy ended IMAGE_MISSING with the
     bytes sitting in the registry under a name nothing reads. `294fa11`.
  8. **qits-artifacts' deployments.yml still said
     `deployment_target: platform`** — the deployer ran the platform plane,
     whose predecessor search cannot match the tier-named seed
     (dev-qits-artifacts), so nothing handed over the 8081 publish and the
     successor died on the port bind. Now `environment` (`e114e9b`); the
     platform-registered catalog row poisoned that run's platform, cured by
     the next unwrap.
  **FINAL PROOF RUN GREEN (2026-08-11 ~11:00): exit 0, 66 phases ok, 1 skip
  (warm wrapper), ZERO warns, 27m11s, one `./qits-local-up.sh` call on fresh
  data volumes.** 16 containers, all healthy, all deployed-shaped
  (`qits-pd-*`) — every seed replaced by its CI-built successor through the
  bus, edge 200. The byte-plane split topology is PROVEN end to end,
  including the 16-deployable train and the postgres cutover mid-train.
  Deferred: qits-deployments' own stale
  microprofile `git-host-url` default (ride its next release); the release
  pipelines pushing `:$QITS_CI_SHA` instead of `:$version` despite their
  headers (platform-wide question, found while fixing qits-projects);
  converting the remaining `--network qits-net` docker builds (workspaces,
  projects, artifacts, ci — passing today only via the deprecated
  legacy-builder fallback, and the swarm migration cannot assume it) to the
  `--network host` doctrine pattern. qits-docs is DONE (`c971981`,
  2026-08-11): its flag was needless — the build reaches only Maven Central
  and nodejs.org, and the `FROM` lines resolve via the host daemon — so it
  builds on default networking now, proven by a real green buildkit build.
  Note found on the way: qits-docs has NO ci-event-release.yml (post-receive
  + deployments.yml only), same asymmetry as qits-deployments.

- **BYTE-PLANE SPLIT CUTOVER EXECUTING (2026-08-10 night).** Full design +
  sequence: `byte-plane-split-plan.md`; state ledger: the
  `byte-plane-split-campaign` memory. Everything is merged on local mains
  (wrapper commit `c240047` renamed 4 submodules + added qits-blobstore,
  qits-registries, qits-platform-mirror, qits-githost). The platform is
  UNWRAPPED (`--with-data-volumes`; config volumes kept). Boot attempt 1
  failed at the gateway seed image (Dockerfiles named `localhost:8081` for
  third-party bases; hole was latent pre-split — cold boots survived on
  docker's image cache). Fixed by a 29-repo sweep to `localhost:8082` (the
  mirror; SeedDockerfile maps 8082-refs to direct upstreams at seed time).
  Boot attempt 2 got past the fleet-sweep fix (gateway/edge/mirror seed
  images built) and died on the artifacts seed image: its pom still
  pinned auth-core 2026.807.165756 — the one train bump the repo missed
  while the split branch carried it (seed registry only holds what the
  checkouts build: 2026.810.184518). Bumped (`0be6cc5`), 89 service
  tests green, whole fleet's pins audited — artifacts was the only
  outlier. Attempt 3 died one layer deeper (Quinoa: no package.json):
  the CLI's source clone fetches nested webui submodules from GITHUB,
  and the artifacts webui gitlink (`a485f88`) named `dce2c5f`, a
  local-only commit — pushed qits-spa-artifacts main to GitHub
  (e3f010d..7773b89) and fresh-inited the source clone's module (the
  `update = merge` convention chokes on shallow histories; module state
  nuked and re-inited). CLI hardening follow-up: `submodulesShallow`'s
  result is silently ignored — the empty-webui context should have
  failed phase 10, not surfaced as a Quinoa error two layers later.
  Attempt 4 reached 7m55s — ALL seed images built (artifacts 1m50,
  githost 1m31), postgres+mirror+store serving — and died publishing
  qits-registries: its pom declared no repository for qits-blobstore
  (local builds rode ~/.m2; a publish container has no cache), and the
  publish container's settings carried only the central mirror. Fixed
  both sides: registries pom names the `qits-maven` repository with
  snapshots enabled (`5bd24d4`, pushed), the CLI's publish settings gain
  the exact-id qits-maven mirror (`277048b`, 226 tests green) — which
  preemptively covers the githost-events publish (eventstream from the
  same store). Attempt 5 then reached phase 42/69 — the ENTIRE seed
  stack proven on the split topology (all seed images, 10 DBs,
  mirror-fronted publishes incl. registries resolving blobstore, step
  images, ci-daemon, seed stack up with dev-qits-artifacts +
  dev-qits-githost + qits-platform-mirror serving, 37 repos on the
  githost, 21 release histories) — and died on the predicted watch
  item: replaying never-released qits-blobstore. Fix per the phase's
  own doctrine (a replay restores a pin; nothing pins a lib calver yet
  — the seed publishes restore the snapshots every consumer names):
  blobstore/registries left RELEASE_PUBLISHERS until their first real
  release (`bd9ac0b`, 226 tests green). Attempt 6: the EVENT
  ARCHITECTURE PROVED ITSELF — the replay's tag push flowed as
  SCMPublishTag through the bus and CI started the release run — then
  the step container died on the one artifacts coordinate the rewiring
  missed: QITS_CI_DAEMON_BINARY_URL_TEMPLATE still defaulted to the
  retired alias. Set in seed compose + run-args (next commit on cli
  main), 226 tests green. Attempt 7 running — remaining unproven: the
  replays' run bodies, environment, 16-deployable train, train push.
  Earlier fixes, landed: artifacts README
  cache-section purge + webui gitlink, and the BOOT-BLOCKING path-aware
  lockfile retargeting —
  PROVEN and landed EVERYWHERE (720-entry proof; broad-then-narrow sed;
  @qits → hosted origin via derived path, rest → mirror; committed
  canonical form 8081-hosted/8082-proxy): 8 SPA repos + 9 service repos'
  webui builds, 33 files, 75 step scripts bash -n clean. ui-components
  turned out pnpm (no resolved origins — replay safe). Stale webui
  checkouts are harmless (service builds use the SERVICE's pipeline
  scripts). Also flagged: qits-spa-docs has NO CI pipeline yet. Then `./qits-local-up.sh` (NO second unwrap). Standing
  order: after a clean end-to-end pass — or after giving up — update this
  file and SHUT DOWN the Windows host. Deferred to next session: calver
  releases of qits-blobstore/qits-registries (+ githost-events off its
  1.0.0-SNAPSHOT) and the consumer pom bumps; dockerd `registry-mirrors`
  host step → `localhost:8082`; user git remotes → `localhost:8083/git/…`;
  a NEW artifacts migration (V14) deleting V7's three `oci-mirror` rows +
  `oci_mirror_upstream` rows — the OCI mirror code path in artifacts is
  still live behind those rows (arc excludes only the profile bean) and
  the store census counts their bytes nowhere; benign tonight (nothing
  dials artifacts for third-party), wrong long-term. AGENTS.md's git-host
  chapters still need their own removal pass. README/AGENTS cache purge
  landed (`5cc15e9`, net −341 lines) + webui gitlink `a485f88`.
  **Plan-doc audit (2026-08-11): byte-plane-split-plan.md verified item by
  item — everything implemented or tracked here EXCEPT two orphans, now
  recorded:** (1) the mirror's phase-2 admin JSON API + explorer UI — DONE
  2026-08-11, see the frontends entry at the top of this file; (2) the
  qits-spa-artifacts package/angular project-key rename (still
  `qits-platform-spa-artifacts`; the CLI pins the old dist path,
  PlatformModelTest:167-176 asserts it). The plan doc STAYS until these and
  the 10 by-name references to it (githost/artifacts/mirror READMEs,
  AGENTS.md, ArtifactsRepositorySeeder) are cleaned up.

- **Causation rows: RELEASED and wired into qits-ci (2026-08-10 night).**
  Libs released through the real door: qits-eventstream `2026.810.184513`
  (causation over REST + CausedRow rows) and qits-integrations-quarkus
  `2026.810.184518` (qits-arch-rules; its release recipe now names/probes both
  modules). Registry verified, train fired: ci + workspaces auto-bumped;
  workspaces' bump released cleanly. qits-ci's bump release MERGED but its
  native build FAILED environmentally (GraalVM `Compilation exceeded 300s`
  bailout — two native builds of one commit racing my local suite on one
  host); superseded by the causation release below, not replayed. The
  auth-core train bump 409'd (pom conflict, adjacent property lines vs the
  eventstream bump) — folded into the qits-ci release below; its stale
  `maintenance/qits-integrations-quarkus` branch can be ignored.
  **qits-ci is the worked example** (`b9e0dd2`): CiRun implements CausedRow
  (V2 adds nullable `causation_id`; trigger_event_id untouched), CiStep +
  CiDaemonPin are `@Uncaused` with reasons, ArchRulesTest enforces the
  decision, and AGENTS.md narrows "ci/ free of the bus" to "free of the bus's
  SEAMS" — the persistence trio rides into the domain module deliberately,
  whose suite now feeds the eventstream PU (`eventstream_ci_domain`) and
  keeps it dark. Reactor green (371 tests). WATCH ITEM: first native binary
  with an @EntityListeners listener — Quarkus registers JPA listeners for
  reflection, but the proof is the deployed binary stamping a real row.
  **Fan-out sweep DONE, LOCAL ONLY (rebootstrap started mid-sweep — NOTHING
  pushed, all three commits sit on local submodule mains and ship via
  bootstrap or the post-rebootstrap releases):**
  - qits-workspaces `5caa2f5` (+ merge `e42d4dc` — local main also carries
    two OLDER unpushed "PushCausation" commits from before tonight):
    Workspace + WorkspaceEvent are CausedRows (request-thread writes, stamp
    via restored REST scope; V2 migration); ServiceEvent (scheduler threads),
    BootstrapRun (overwritten singleton), WorkspacePromptDraft (NATIVE
    upsert — @PrePersist can never see it) and WorkspacePromptAttachment are
    @Uncaused with reasons. 464 tests green.
  - qits-deployments `a07d1e9`: PdDeployment + PdService + PdEnvironment are
    CausedRows — PdDeployment carries the cause AS DATA through a new fifth
    `BuildAnnouncements.announce` parameter (subscriber passes `frame.id()`,
    HTTP intake passes `CausationScope.current()`), because everything past
    announce runs on `pd-deploy-worker` where no scope stands; PdServiceLink
    (wholesale-rewritten link set) + PdResource (converging registry) are
    @Uncaused. One V2 migration in environments/ (the single lineage owner).
    ArchRulesTest in service/ — the only classpath seeing all five entities —
    and proven non-vacuous. Also folds the auth-core bump to 2026.810.184518.
    286 tests green.
  - qits-projects `0333745`: Project, Repository, Epic, Feature, Task AND
    AuditEntry are CausedRows (request/MCP threads; audit rows cover what
    insert-only stamping on live rows cannot — updates and deletes); only
    RepositoryName is @Uncaused (derived alias minted off any request
    context). Two V2 migrations (domain, epics lineages). Bumped eventstream
    to 2026.810.191553 by hand — **this repo has NO
    ci-event-upstream-eventstream.yml, so the train never bumps it; add the
    recipe** (follow-up). 536 tests green; webui gitlink verified unmoved.
  - qits-arch-rules `f4bb41a` (LOCAL, unreleased): all three rules gain
    `allowEmptyShould(true)` — projects' epics module (all-participating,
    zero opt-outs) went red under ArchUnit's fail-on-empty default, the
    ideal state read as a misconfigured rule. Its interim workaround
    (`epics/src/test/resources/archunit.properties`) is removable once a
    release carrying this is pinned.
  **POST-REBOOTSTRAP TODO: DONE (2026-08-11 night, the DB-patience release
  campaign carried it):** qits-integrations-quarkus released (.152803 +
  .165001), then workspaces / deployments / projects shipped with their
  causation commits aboard. Original queue, for the record: release
  qits-integrations-quarkus (the empty-should fix + qits-db-core), then
  workspaces / deployments / projects through
  the release door sequentially (each also needs its ArchRulesTest happy —
  projects is, via the workaround); then drop the workaround on projects'
  next touch. The three service repos' working trees also carry the byte-
  plane split's UNCOMMITTED Dockerfile mirror moves (8081→8082) — the other
  party's, not part of these commits.
  **Deliberately excluded from the sweep**: qits-events (the bus server —
  its rows ARE the events, a client dep would be circular),
  qits-platform-idp/dns + qits-artifacts (not on the bus; wiring means the
  whole eventstream jar + a provisioned database just to say @Uncaused —
  decide when they adopt the bus, cheaper after
  eventstream-causation-split-plan.md lands), and
  githost/blobstore/registries (byte-plane split, in flight, hands off).
  **Tomorrow's cleanup**: eventstream-causation-split-plan.md — split
  qits-causation out of the eventstream jar so entity modules stop
  inheriting an HTTP server, a persistence unit and darkness keys; the
  plan carries the exact per-repo removal inventory.
  **Live rollout (same night):** qits-ci `2026.810.191049` built green on
  both branches and deployed (container on image tag `bc24bdc9…`, V2 applied,
  `causation_id uuid` confirmed in qits_ci). The FIRST live event runs then
  measured the gap the javadoc had hand-waved: `trigger_event_id` full,
  `causation_id` EMPTY — the row is written on `ci-trigger-worker` behind the
  queue hop, where the ambient scope is dead, so the stamp wrote null. Fixed
  as data, the repo's own idiom: `acceptEventRun` sets the cause explicitly
  and the stamp yields; the manual trigger keeps the stamp path (request
  thread, REST-restored scope). Released as qits-ci `2026.810.191920`
  (`9fecbcc`) with `CiEventRunCausationTest` driving evaluate from a
  scopeless thread. Eventstream Alpine fix also released
  (`2026.810.191553`; the Alpine/musl zonky binaries the main-branch verify
  run dies without — its train wave went green: workspaces + ci + deployments
  bumps all released). **Two builds were eaten by qits-ci's own redeploy**
  landing mid-wave (RUNNING push rows → FAILED at boot reconciliation, the
  documented restart semantics; the main event runs were reset and finished
  green): qits-ci env/dev @`a869fe57` and qits-deployments env/dev
  @`4ec65654`. Both squared by the rewind-replay trick the same night — with
  one lesson bought twice: **replay the self-hosting qits-ci's own deploy
  build LAST and ALONE**, because its green build redeploys qits-ci, whose
  boot sweep then eats every other push build in flight (it ate the
  deployments replay's first attempt; the second, against an empty queue,
  went through).
  **Confirmation probe: CLOSED, proven live.** A fresh-id SoftwareRelease
  replay of eventstream 191553 through the manual trigger (machine token:
  client qits-platform-artifacts, audience `dev-qits-ci` — the dev spelling,
  `qits-ci` is refused) recorded three event runs on the fixed binary, all
  with `causation_id == trigger_event_id`, and the bump recipes no-op'd
  (same version, no release). Causation rows work end to end on the live
  platform.
  Also open: the auth-core train bump never landed for qits-deployments (its
  `maintenance/qits-integrations-quarkus` build failed on the same pom
  adjacency); harmless — auth-core content is unchanged — and it self-heals
  on the next integrations release.

- **Causation reaches the rows, with an arch-rules guard (2026-08-10 night,
  superseded by the entry above).** qits-eventstream
  `13048b4`: `CausedRow` + `CausationStamp` (JPA `@PrePersist` listener) stamp
  a nullable `causation_id` column from `CausationScope` at `persist()` — on
  the calling thread, not at flush, proved by closing the scope before the
  commit against a real default persistence unit (suite now 115). Insert-only,
  author's value wins, never an FK; `@Uncaused` is the written opt-out.
  qits-integrations-quarkus `0369591`: NEW MODULE `qits-arch-rules` (ArchUnit
  1.4.1) — one test-scope dep + a three-line `ArchRulesTest` makes every
  `@Entity` decide (implement CausedRow with the listener, or declare
  `@Uncaused`); types are matched BY NAME so the module depends on neither
  eventstream nor the registry, and renaming CausedRow/CausationStamp/Uncaused
  over there breaks this contract knowingly. Enabling the rules is now step 7
  of docs/project-setup-quinoa-angular.md's checklist. NOT DONE YET: no
  existing service entity participates and none carries the rules test —
  wiring one real service (entity + migration + ArchRulesTest + @Uncaused
  sweep over its remaining entities) is the natural next workstream; both
  libs also still need their releases cut so consumers can pin them.

- **Causation over REST landed in qits-eventstream (2026-08-10 evening, lib
  `2aadf40`, local main — not yet on the platform git host).** The chain now
  crosses a service boundary: `CausationClientFilter` writes
  `CausationScope.current()` into every REST-client request as
  `X-Qits-Causation-Id`, `CausationServerFilter` restores it around the
  receiving resource method, so event 1 in service A triggering event 2 in
  service B keeps its parentId with neither side passing anything. Both are
  `@Provider`-discovered; the header sits in the gateway's stripped
  `X-Qits-*` namespace so outsiders cannot forge a cause. The pom gained
  `jakarta.ws.rs-api` (API jar only — never quarkus-rest, which would bolt a
  server onto the daemons); suite is 110 green, and the wire test proves the
  filter/method one-worker thread assumption. Consumers reach it through the
  train on the lib's next release. Note most services speak
  `java.net.http.HttpClient`, not the REST client — those callers stamp
  `CausationHeader.NAME` by hand (snippet in the lib README) and are untouched
  until someone does.

- **WP6 DONE — the platform is bus-only, proven from scratch (2026-08-10
  evening).** qits-events is a CORE seed service (cli-bootstrap `a69d989`; 59
  phases cold, 7 seeded databases) and ci's direct PdBuildNotifier POST is
  GONE (qits-ci `2bf8d880`; the deployer's HTTP intake stays as the manual
  door only). Gate run: `unwrap --with-volumes` + ONE bootstrap call → exit 0,
  57 ok + 2 skipped, 15m49s, zero warns — every deployment rode ci → outbox →
  seeded bus → the deployer's durable subscriber. Four defects were flushed
  out by the proving runs and fixed at the source: (1) the eventstream lib's
  EventPage/EventFrame were not reflection-registered — catch-up dead in
  NATIVE images only, JVM green (`7290397`); (2) ci's manual trigger endpoint
  202'd events it then silently lost — it now evaluates on the request thread,
  200 = run rows exist, 503 = retry losslessly (`9ac6094`), and the CLI
  retries (`7b1979d` also made the replayed SCMRelease carry BOTH
  `repository` and `repositoryName`, which the daemon repos match); (3) the
  replay skip/wait misidentified runs twice — trigger name and sha BOTH
  collide with upstream-fired bump runs — the identity is `configPath ==
  .config/qits/ci-event-release.yml` at main's head (`58138c2`); (4) an
  event-triggered run records MAIN'S HEAD, not the tag's commit.
  **Bootstrap UI**: the lower region is two columns now — step output left,
  a live qits-events feed right (`18e72c2`, `ev|` in plain logs), and the
  browser page reloads itself when the boot under it changes (`539f341`) —
  a stale tab was measured reading a new run through an old layout.
  **Known state, deliberate:** qits-projects-daemon's images are NOT in this
  fresh registry (the pre-fix over-skip); the user tests with later builds —
  its next release (or any base release driving its bump) republishes them
  through the train. The lib's first-boot watermark-race WARN and the
  workspace-daemon surefire flake remain open cosmetics.

- **Event delivery guarantees SHIPPED (2026-08-10 afternoon; plan:
  event-delivery-guarantees-plan.md).** All on the live dev platform through
  the release endpoint: qits-eventstream `2026.810.103202` (outbox never
  abandons an unreachable bus — refusals alone consume the attempt budget; new
  `QitsDurableEventListener`: consumed-event table + watermark + catch-up
  sweep on the consumer's eventstream datasource, exactly-once effect,
  consume-from-now init, selective storage, lib migrations V2/V3);
  qits-events `2026.810.104520` (`order=asc` on the list endpoint, tie-safe
  both directions); qits-ci `2026.810.110535` (three durable listeners:
  `ci-event-triggers`, `ci-release-train`, `ci-daemon-adopt` — the last with
  the pin-rollback tip check); qits-deployments `2026.810.111624` (wave 3 as
  BuildAnnouncements recorded: durable `pd-build-succeeded` subscriber with a
  newest-green tip guard, HTTP intake kept as the manual door). The TRAIN
  itself propagated the lib: one release auto-bumped and auto-released ci AND
  workspaces. **Bus side of the deployer is LIVE** (marker release
  `2026.810.123234`; the successor boots with the injected eventstream triple
  + QITS_EVENTS_URL and logs `durable consumer pd-build-succeeded initialized
  at the head of the log`). WP6 — retiring ci's direct PdBuildNotifier POST —
  waits until the bus door has visibly carried a few organic releases.
  Known cosmetic lib bug for its next release: on a consumer's FIRST boot the
  startup sweep and the scheduler race to insert the initial watermark and the
  loser WARNs a `consumer_watermark_pkey` violation — make the init insert
  idempotent. Second known flake: qits-workspace-daemon's surefire suite
  failed once on a maintenance-branch REBUILD of a tree that had built green —
  unreproduced, worth an eye.
  **Tag discipline, learned the hard way:** a branch-only `git pull` carries a
  release commit but NOT its tag, and the release replay reads the version off
  the newest reachable tag — converge-7 re-released qits-oci-workspace at the
  PREVIOUS version and drove qits-projects-daemon's base pin backwards through
  the follow-bumps (self-consistent; the next real base release walks it
  forward). Fixed twice over: local syncs fetch --tags and the CLI's sources
  refresh pulls --tags (`574b04f`); replays also skip entirely when a green
  run for the version already exists (`45c21bf`). Fitting last act of
  the old world: the base image's SoftwareRelease fired inside qits-events'
  own redeploy window and was the final manually-replayed lost event — the
  durable consumers make the class impossible now.

- **Workspace images ride the train, END TO END PROVEN (2026-08-10; plan:
  workspace-image-train-plan.md).** No more hand-built `qits/*:latest`. The
  full cascade ran live: qits-oci-workspace release `2026.810.104734` put
  `qits/workspace-base` into the registry for the FIRST time (the old pin
  always dangled — the wipe had taken the image and nothing rebuilds images/
  repos unprompted) → qits-workspace-daemon's FROM-pin bump → its release
  `2026.810.112023` published `qits/workspace` (one build: native daemon
  layered onto the pinned base; the two old names retired; consumers' spelling
  kept deliberately) → qits-workspaces' pin bump → release `2026.810.113255`
  deployed the pull-if-absent launcher
  (`qits.workspace.image=localhost:8081/qits/workspace:2026.810.112023`,
  15-min bounded pull, loud failure naming image+registry). Image pull
  verified on the host daemon (970 MB, entrypoint qits-workspace-daemon).
  The PROJECTS side had been train-wired on 08-09 and completed ITSELF the
  moment real artifacts existed: projects-daemon released `2026.810.104935`
  (its own base-pin bump, publishing versioned qits/projects-daemon +
  qits/project-agent) and qits-projects followed with `2026.810.105222`.
  Bootstrap carries it all (cli-bootstrap `6959271`): three image publishers
  in the release-replay set (base strictly before each daemon), 58 phases
  cold, deployer bus env in compose + run-args, sixth seed database
  `qits_deployments_eventstream` with recorded password.
  **Gotcha now recorded in two trigger files:** `$QITS_REGISTRY` is the HOST
  daemon's `localhost:8081` and is unreachable from inside a step container —
  registry probes must derive the origin from `$QITS_MAVEN_REGISTRY_URL`
  (measured twice; the workspaces bump died on it once before the fix,
  6e7f656).

- **The standing environment is `dev` now (2026-08-10, user decision).** Run 5:
  `unwrap --with-data-volumes` (config volumes kept) + one bootstrap with
  `QITS_ENV_NAME=dev` (wrapper .env) — exit 0, zero warns, 11m27s. First real
  proof of `--platform-env`: nine env services live as `qits-pd-dev-qits-*`,
  five platform services bare, deploy ref `environment/dev`, edge 200. The
  kept config volumes carried the push token; run-args were rewritten in dev
  shape; the prod-named recorded secrets are unused, dev ones recorded beside
  them. All of the day's commits are pushed to GitHub main (wrapper `4ca068b`
  + six submodules).

- **From-scratch rebootstrap campaign (2026-08-10): DONE — run 4 GREEN.** One
  `./qits-local-up.sh` call, exit 0, 54 phases ok + 1 skipped, ZERO warned
  phases, 19m17s, no manual pokes. 14 containers healthy, edge 200, and the
  fresh seed came out **UUID-free (36 repositories, 0 UUID-keyed rows)** — the
  d795bdc verification the entry below asked for is done. Runs 1–3 each failed
  differently; every failure was root-caused and fixed at its source (see the
  measured list below). Run 3 added one more: the CLI's shared HttpClient
  reused a connection made during idp's crash-restart DNS flux and read 90s of
  404 from a WRONG peer while idp was healthy — fixed in cli-bootstrap
  `8dfa60c`, a fresh client (fresh lookup, fresh connection) per request;
  pooling must not come back (AGENTS.md gotcha). Follow-on workstream settled
  with the user and planned: `event-delivery-guarantees-plan.md` — durable
  consumption in qits-eventstream (consumed-event table + watermark + catch-up
  against the query API, selective storage), outbox give-up split
  (unreachable ≠ refused), qits-events ascending list mode, deployments wave 3,
  then retire ci's direct PdBuildNotifier POST. Still standing after any
  volume wipe: qits/workspace:latest must be re-layered (recipe in memory) —
  the closing report prints this.
  What the proving runs measured:
  - **Lost post-receive (artifacts→ci), deterministic.** Phase 41 deploys
    qits-oci-postgresql — the platform's own database — and the cutover severs
    every pool; phase 42's idp push announcement arrived at ci in that exact
    window (`FATAL: terminating connection due to administrator command`), the
    fire-and-forget notifier swallowed the refusal at debug, no run was ever
    enqueued. Hit identically on both runs.
  - **Lost build-succeeded (ci→deployments), transient.** qits-platform-docs'
    green run at 06:36:07 left no trace at the deployer; the same POST replayed
    by hand minutes later answered 202. Most plausibly the idp cutover's
    token/JWKS trailing edge. Platform services have no CLI-side replay, so it
    cost a 1h timeout.
  - **Dead event bus from the seed ci.** The eventstream jar bakes
    `qits.events.url=http://qits-events:8080` (pre-rename); the seed compose
    never overrode it, so every outbox delivery (BuildSuccessful,
    SoftwareRelease) died on ConnectException after its five attempts. The
    deployed ci gets the right value from run-args; only the seed was blind.
  - **qits-projects webui gitlink named a vanished commit** (`e8d020e5…`, a
    release-train commit that lived only on the old git host — the
    AUTH_REQUIRED backup era never carried it to GitHub, the wipe destroyed
    it). Every CI build of qits-projects died on "unadvertised object".
    Full sweep done: all other webui gitlinks resolve against their spa's
    local main.
  - **dns had no ci-post-receive.yml** — the known Package C gap; the overlay
    path works but warns, which fails the green bar.
  Fixes, all committed on local mains (they ship via the bootstrap):
  qits-cli-bootstrap `db9d3de` (re-announce a pushed sha with no run after 60s
  — uses the existing reannouncePush; plus `pd|` deployer-log relay beside the
  `ci|` one, so deploy waits talk) and `b85fd7e` (seed ci gets
  QITS_EVENTS_URL); qits-projects `cdc34e6` (webui gitlink → spa main head
  `61fb5c1`); qits-platform-dns `64bf337` (both CI pipeline files, edge's
  shape); qits-platform-artifacts + qits-ci: bounded-retry + WARN-on-give-up
  for the two direct announcers (subagents, shas in their logs). Also new:
  `.env` at the WRAPPER root (the CLI reads `.env` from the run directory,
  which qits-local-up.sh pins to the wrapper — the copy in
  cli/qits-cli-bootstrap/.env is NOT read on the warm path; QITS_DNS_PORT=5353
  lives in both now).

- **UUID repository ids FIXED at the root in qits-projects** (`d795bdc`,
  released as 2026.809.194051 / `e5476e0`, 2026-08-09). Every creation path
  (`cloneOne`, `initWrapperOrigin`, `createBlankRepository`, the reconcile's
  clone branch) now keys the row by its addressable name — entry name,
  `<slug>-<slug>` for wrappers, url basename for plain clones — via
  `requireCreatableId`; invalid or taken name is a hard 400, no UUID fallback
  anywhere. Adoption unchanged; a retried clone re-adopts instead of orphaning.
  Derived project slugs capped at 31 chars so `<slug>-<slug>` fits the id
  shape. Full `./mvnw verify` green (new `PlatformStateReset` per-method state
  wipe because ids are deterministic now). **Existing envs keep their six UUID
  rows** (wrapper `b21f6d39…`, workspace-daemon, repositories, platform-dns,
  cli-bootstrap, projects-daemon) — reconcile matches them by alias, so they
  are stable; only a fresh seed or the manual repair recipe renames them. Next
  fresh seed should come out UUID-free; verify that.

- **Deployment status observer LANDED in qits-deployments** (`6846614`,
  2026-08-09; full `clean verify -DskipITs=false` green, 188+9). Periodic pass
  on the deploy worker (bare `pd-observation-ticker`, 30s, collapses stacked
  ticks): latest row per (app, tier) checked against its own container;
  FAILED-but-healthy recovers to ACTIVE (detail appends, old failure kept —
  and the recovery decommissions stale prior ACTIVE rows, keeping the
  one-ACTIVE invariant), ACTIVE demotes to FAILED only on absent/exited over
  two consecutive passes; restarting and running-unhealthy are patience.
  Writes rows only, DbRetry-wrapped. SHIPPED as release 2026.809.193248
  (env branch, deployer self-updated to `4184d93`) — and PROVEN live: the
  eaa34fbc row flipped to ACTIVE on the observer's first pass at 19:35:56,
  recovery stamp prepended, original JDBC failure preserved. The edge shipped
  too: release 2026.809.194017 (`cf1adc7`), cut over healthy, management
  interface listening on 9000 (unpublished), TLS slot dormant. dns and
  cli-bootstrap have NO platform repo yet (git host 404s) — dns arrives with
  the next bootstrap run; both are backed up on GitHub main along with the
  released repos and the wrapper.

- **`QITS_DOMAIN`: Let's Encrypt on the edge, qits-platform-dns becomes a core
  service** (2026-08-09, three Opus agents implementing; plan in
  `qits-domain-letsencrypt-plan.md`). Package A LANDED (edge `7afa9e4`): build-time
  `quarkus.tls.lets-encrypt.enabled` + management interface on 9000, with
  `quarkus.smallrye-health.management.enabled=false` so `/q/health` stays on
  :8080. Measured: challenge endpoint 503s keystore-less ("No keystore
  configured"), management routes are `/q/lets-encrypt/{challenge,certs}`, and
  the proxy catch-all provably cannot land on the management router (it is a
  `ManagementInterface` event, not a `Router` observer) — no open proxy on
  9000. Package B LANDED (dns `22613aa`):
  quarkus-smallrye-health + `health_path: /dns/q/health/ready`; measured
  readiness carries the agroal datasource check, liveness is an empty check
  list, `/q/health/ready` 404s (pinned). Package C LANDED (bootstrap `090199d`): dns is
  a core platform service (seed image, compose, deploy, run-args, health poll
  at `/dns/q/health/ready`; new `QITS_DNS_PORT`, default 53, UDP+TCP), and the
  new optional `QITS_DOMAIN` gates: dns NS/hostmaster env, idempotent zone
  POST, edge TLS run-args (80/443/9000-loopback, `qits-edge-letsencrypt`
  volume — survives `unwrap --with-data-volumes`, pinned — acme PEM keystore
  env, reload-period), self-signed placeholder cert seeding (alpine/git +
  `apk add openssl`; alpine/git carries no openssl, measured), and a
  closing-report staging issuance command. Unset domain = today's rendering
  plus only the dns additions. Cert issuance stays a host-side `quarkus tls
  lets-encrypt` CLI step against ACME **staging** for now.

  **THIS HOST cannot bind 53** (systemd-resolved + WSL stub; measured
  `address already in use`, which fails the whole seed stack at compose up) —
  `QITS_DNS_PORT=5353` is now in `cli/qits-cli-bootstrap/.env`. The dns repo
  still lacks a `.config/qits/ci-post-receive.yml`, so its first deploy takes
  the "no pipeline config" overlay path (warn + bootstrap commit) — worth
  giving it one later. NOT yet proven by a real bootstrap run.

- **The bootstrap runs in a container, and a bare box boots from a pipe**
  (2026-08-09, MERGED to both mains and pushed to GitHub; NOT yet proven by a
  real bootstrap). qits-cli-bootstrap `748eb29`, wrapper `b68e4cd`.

  The CLI ran on the host and dialled published ports. It now builds a payload
  image of itself, runs inside it on `qits-net`, and dials **wire aliases**.
  `InNetworkHttp` is gone with it — the throwaway curl container per HTTP call
  existed only to reach services with no host port.

  **The payload is the static musl native binary.** Two hard reasons, both
  measured: a glibc-linked binary does not execute on alpine at all, and a
  *static glibc* one cannot resolve DNS (NSS is dlopen-based) — which the wire
  aliases need. musl-static does both. The pattern is qits-ci-daemon's
  `Dockerfile.musl-builder`, vendored rather than shared. Image 600 MB → 350 MB.
  **There is no jar in that repository any more, in any form** — three pom
  changes were needed, because `quarkus.package.jar.enabled=false` alone fails
  the JVM build with `No artifact results were produced`.

  **`curl … | bash` is the point.** An absent wrapper is now cloned from GitHub
  (the platform git host is what the bootstrap is *creating*, so it cannot be the
  source). Submodules are deliberately NOT initialised: `sources()` clones each
  component from the org anyway. A bare wrapper clone leaves an **empty directory
  at every one of the 29 gitlinks**, which tripped the "exists and is not a
  checkout → stop" guard; an empty directory now counts as absent.

  Open: **the TUI has never run under a real TTY** (no agent or session here has
  one, so only `PlainUi` is proven), and **no real bootstrap has been run**. The
  cold path's `docker build` from the public git URL is proven; the cold run has
  no browser view (publishing it would mean reimplementing `BootstrapConfig` in
  shell) and logs in UTC.

- **Configurable platform environment (`--platform-env`)** (2026-08-09, IN
  FLIGHT): plan in `~/.claude/plans/we-currently-have-the-structured-snail.md`.
  Three things landed together.

  **`pd_environment.platform`** (qits-deployments V2, backfilled onto the one
  existing row). `DeployService.registerPlatform` now asks whether the *platform*
  environment listens to the built branch, not whether *any* environment does.
  That closes the hazard qits-deployments' own AGENTS.md recorded as gating
  environment #2: under the old gate any tier's branch rolled the single platform
  instance, which was never a fan-out — it was tiers taking turns overwriting one
  container. Designation MOVES (clears the old holder, sets the new one, one
  transaction) because H2 has no partial unique index; clearing it is a 409 and so
  is deleting its holder. **A second environment is an ordinary thing to create
  now.**

  **`deploy_branches` is retired.** It was a per-repository list read only by
  qits-workspaces' release flow, which pushed the released sha onto *every* entry
  — a fan-out, not a ladder, and three tiers listed would have shipped into all
  three at once. Every one of the thirteen copies named the same ref anyway.
  Replaced by `qits.workspaces.release.entry-branch` (one branch, from config, set
  by the bootstrap's run-args). What a repository still decides is *whether* it
  deploys, by carrying `.config/qits/deployments.yml` at all;
  `DeploymentSpecReader` is a five-line `isRegularFile` check now. The deployer's
  strict parser still TOLERATES the key and must keep doing so — a spec is fetched
  at the built sha, so rollback pins and older commits still present it.

  **`qits bootstrap --platform-env <name>`.** Names the standing environment,
  which is also the platform one. Bootstrapping over a platform whose environment
  has another name is REFUSED, not renamed: the name is inside every wire alias,
  container name and recorded idp secret key. The old `List.of("qits","dev")`
  rename is gone with it.

  **SHIPPED AND PROVEN LIVE.** qits-spa-deployments `2026.809.65926`;
  qits-deployments `2026.809.70001` — V2 migrated on the live database and the
  backfill designated prod, self-update handoff clean; qits-workspaces
  `2026.809.70822`, which boots logging `Releases land on environment/prod`;
  qits-platform-docs `2026.809.71259`.

  That last one is the end-to-end proof and it exercises both halves at once. A
  PLATFORM service, released with **no `deploy_branches` anywhere** — promoted
  onto `environment/prod` from qits-workspaces' config alone — and deployed only
  because prod carries the new flag. It landed platform-shaped: ACTIVE at
  `9e95ac60` with no environment id, container
  `qits-pd-qits-platform-docs-30ffe1d9`. The deployments SPA shows `platform` on
  the prod card and `deployed from environment/prod` on the platform bucket.

  **A landmine was hit and is now in memory:** `git add -A` in a repo with an
  `ignore = all` submodule stages a moved gitlink **without showing it**, and
  `git diff-tree`/`git show` are suppressed too. It rewound qits-workspaces'
  webui gitlink to a commit whose lockfile pinned a dropped ui-components
  version; the `environment/prod` build died on npm E404 and needed a second
  release (`70426` is the burned stamp, `70822` the good one). Stage explicit
  paths; read a gitlink with `git ls-tree <commit> <path>`.

  **Still open:** the 11 remaining spec-only commits sit on each submodule's
  local `main`, unpushed. They are inert — nothing reads `deploy_branches` any
  more — so they ride with each repo's next ordinary release rather than costing
  eleven builds. qits-cli-bootstrap is committed locally and unpushed, and
  **`--platform-env` has had no real bootstrap**: `clean verify` (102 tests) and
  the rendered help are all that is claimed, and that repo's AGENTS.md says a real
  bootstrap is the only test its phases get. The refuse-on-conflict branch in
  particular is unproven end to end.

  **Not in scope, and deliberately:** moving the platform plane between tiers on
  a live platform. The column and the PATCH exist; the undeploy/redeploy does not.

- **Epic refining workspace (Refine button + refining page)** (2026-08-08, late
  evening, IN PROGRESS): plan + decisions in `epic-refining-workspace-plan.md`.
  A REFINING epic gets a third action **Refine** (ordered before Start
  implementation | Abandon) that starts a REAL qits-workspaces workspace on the
  project wrapper repo, branch `refining/<epic-slug>` (new convention, fresh
  top-level prefix — no conflict with epic/feature/task), then opens
  `:projectId/epics/:epicSlug/refining` — a copy of the Workspace Detail UI
  into qits-spa-projects. Zero backend change: `POST /workspaces/api/workspaces`
  already creates the branch itself (git-host push, post-receive fires), the
  browser is the integrator (STT precedent), which keeps the service arrow
  one-way. The refining workspace is LOOKED UP by rule (active workspace on
  `refining/<slug>` in the wrapper repo), never stored. Phases: A plumbing +
  Refine flow + shell/tabs/status-strip (running), B terminal/chat/STT,
  C files/web-view/services/actions, then browser e2e via ng serve + proxy.
  Note: today's Workspace Detail has NO sketch canvas (removed by design;
  paste + prompt attachments cover it) — "mirror as of today" = no canvas.
  ALL THREE PHASES LANDED on qits-spa-projects main (5c4b8ba, 866be52,
  1529710 — local, not pushed): 704 tests green, prod build clean (bundle
  warning raised to 650 kB for the copied panels). Browser e2e (ng serve
  :4300 + proxy → live gateway): Refine click on the live epic
  give-the-platform-a-status-page CREATED branch
  `refining/give-the-platform-a-status-page` on the wrapper (git host
  verified, at main's tip) + workspace row 1 (ACTIVE, preamble = rendered
  epic outline) and navigated to the refining page — header, status strip,
  all six tabs render.
  **Platform gap found by the e2e (not a UI bug): the daemon-layered
  workspace image was lost in today's unwrap.** `qits.workspace.image`
  defaults to `qits/workspace:latest`, but today's monolith rebuild of that
  tag is the PRE-DAEMON toolchain base (no qits-workspace-daemon binary, no
  entrypoint) — so ensure-container fails with "no workspace-daemon dialed
  home within 30000ms" and the container is rm'd. Recovery per
  qits-workspace-daemon docker/Dockerfile.workspace: build
  qits/workspace-daemon:latest (native), layer onto the base, retag as
  qits/workspace:latest (old base preserved as qits/workspace-base:latest).
  **Rebuild DONE and e2e PASSED (2026-08-08 ~21:06)**: daemon image
  qits/workspace-daemon:latest built native, layered, retagged; Start on the
  refining page → daemon dialed home instantly, self-clone materialized ALL
  34 submodules on branch refining/give-the-platform-a-status-page
  (container qits-ws-refining-give-the-platform-a-status-page-76f9b6a4),
  working tree clean. Status strip live (running / connected / clean /
  active), Files tab renders the real wrapper tree, Agents tab renders a
  LIVE Claude Code TUI through the copied terminal (shared /claude-home
  credential works in workspace containers too), Chat tab shows the
  dictation + prompt surface (STT route answers through the gateway; a real
  mic take was not driven — headless browser). Zero console errors/warnings.
  Screenshots delivered in-session. The live refining workspace (row 1) and
  its container were LEFT RUNNING for the user to try; ng serve is still on
  :4300 with the proxy at the live gateway.
  **RELEASED AND LIVE (2026-08-08 ~21:15)**: qits-spa-projects
  `2026.808.190906` cut through the branches/release endpoint (branch
  `refining-workspace-ui`, quiet push, flow stamped + deleted it); the
  spa-projects train did the rest itself — maintenance bump `8da096c0`
  green, qits-projects release `55dad56c` built on environment/prod,
  container rolled (`qits-pd-prod-qits-projects-fabe2c06` on the release
  sha). Verified in the browser THROUGH THE GATEWAY on :8080: refining page
  serves live, attached to the same running agent session, zero console
  errors. GitHub backup carried the release commit automatically (the
  AUTH_REQUIRED era appears over — `git pull` from GitHub fast-forwarded
  onto the stamp).
  **Markdown fix (user-reported, same evening)**: epic/feature/task
  descriptions rendered raw on the draft card, epic card and refining
  header. Fixed in qits-spa-projects `19efa89` → released
  `2026.808.193937` (403155b): hand-rolled `renderMarkdown` in
  src/app/ui/markdown.ts (NO npm dep — the ansi-screen precedent; all
  source text HTML-escaped, hostile schemes refused, 46 renderer specs) +
  `app-markdown` binding [innerHTML] with no sanitizer bypass, so Angular's
  sanitizer stays as the second net. 757 tests green. Browser-verified on
  both surfaces before release. Note for the next person: a stale Vite HMR
  error overlay (NG1002) can outlive the broken intermediate state that
  caused it — check the ng-serve log's LAST rebuild before believing it.
  **Open:** decide whether the workspace-image recipe (base from the
  retired monolith + daemon layer) finally gets a home; prompt-attachments
  still has no SPA client in either SPA (paste delivery unwired).
  Two genuine source-UI gaps discovered while copying (worth their own
  tasks): prompt-attachments has a backend + SSE topic but NO SPA client
  calls it (paste/sketch delivery is unwired in workspaces too), and the
  ui/async.ts copies have drifted between the SPAs.

- **Epics MCP wired into the refinement harness** (2026-08-08 evening, SHIPPED):
  qits-projects 2026.808.174338 states the MCP address (`QITS_REPOSITORY_MCP_URL`
  composed from own-host + /projects/mcp; `qits.projects.agent-mcp-url` overrides;
  no new run-arg needed); daemon 545cdd7 pre-approves the two epic READS only,
  `--strict-mcp-config` proven live to exclude everything else incl. the signed-in
  account's claude.ai connectors. 15 tools (10 epic + 5 repository) reachable from
  the container. Claude sign-in completed ~17:30 — the credential gate is PASSED.
  **Browser e2e PASSED** (2026-08-08 ~17:53): one prompt → epic "Give the platform
  a status page" created through the MCP, card appeared via SSE mid-turn WITHOUT
  reload, 6 features streamed live; REFINING; epics audit rows all
  `changed_by=mcp-agent`. Screenshots in the session scratchpad verify/ dir.
  **Defect found (blocks task attachment)**: AgentLaunchService:604 puts the repo
  NAME into the MCP `repositoryId` param; RepositoryMcpTools:76 filters by ID —
  silent empty for UUID-id repos (the wrapper included), so the refinement session
  lists zero repositories. Converged fix pending user go: launch the panel session
  in PROJECT scope (SPA `scope:` + daemon interactive path — the panel is
  project-level) AND fix the name/id param for legitimate REPOSITORY-scope uses.
  (2) ScopedMcp.allowedTools is inert on the Claude path but FILTERS on Kimi ACP
  chat (latent — shipped panel uses INTERACTIVE). Observed for the record: the
  harness launches claude with --dangerously-skip-permissions inside the container;
  the e2e terminal held un-submitted input text nobody typed (origin unaccounted).

- **DAY-END STATE 2026-08-08, all verified live**: the prod re-model is COMPLETE
  (12 apps deployed under wire names, edge on :8080 proxying HTTP+SSE+WS —
  browser-verified incl. the PTY terminal; bootstrap rerun converges green
  45ok/3skip; telemetry flowing from 12 sources after the fleet roll).
  Epic-refinement integrated + released (projects 2026.808.152415 via the train,
  agent harness wire PROVEN: daemon HELLO, control socket, hook webhook).
  Maven Central proxy released (2026.808.153400) and smoke-verified (immutable
  cache + blob-store serve + 405 on PUT). health_cmd released (2026.808.155533)
  and postgres PoC deployed on it (2026.808.160429, pg_isready gate, ACTIVE,
  reachable prod-qits-oci-postgresql:5432).
  **Name-resolution seam SHIPPED AND PROVEN LIVE** (2026-08-08 evening), the
  item that was blocking the terminal e2e. Repository names are PROJECT-SCOPED
  by design; what was missing was the resolver behind the name-addressed
  scheme. Three repos:
  - qits-projects `2026.808.171005` publishes
    `GET /projects/api/projects/{projectId}/repositories/by-name/{repoName}`
    → `{"repositoryId"}`, 404 either way for unknown project/name. Unguarded
    with a real `@Operation` — the `GitHostEventController` precedent, because
    artifacts generates its client from docs/openapi.yml. Resolution goes
    through ONE shared method, `RepositoryService.findByProjectAndName`, which
    `WrapperReconcileService.view()` also calls, so the route can never honour
    less than membership does — including the "the name IS the id" fallback
    every adopted platform repo depends on.
  - qits-platform-artifacts `2026.808.170239` ships `HttpRepositoryNameResolver`
    behind `qits.projects.name-resolver-url`. Unset = the port answers nothing =
    today's 404, so absent stays a supported configuration. `@DefaultBean` is
    what keeps `FakeRepositoryNameResolver` winning the test classpath. **It
    never throws** — GitHostRoutes has no exception clause, so a throw would
    turn a 404 into a 500; the opposite of the GC pin ports, deliberately.
    No cache: a rename must not serve a stale id.
  - qits-projects-daemon `4f4dbd9` binds ProjectsApi **even when provision
    fails**. The old javadoc justified not binding with "qits tears the
    container down" — factually wrong: qits only WARN-logged the frame. The
    result was a live container with an unbound API, so the one surface that
    could have shown the error was the one that never bound. The projects side
    now records the failure and reports `FAILED` + `failureDetail` on the
    agent-container read (no sixth enum constant — the SPA switches on those
    five strings).
  PROVEN on the live platform: the projects route resolves the wrapper by
  `qits-qits` and by `qits-qits.git` to `76f9b6a4-…`; `git ls-remote
  /artifacts/git/166c1bc6-…/qits-qits` serves where it 404'd an hour earlier;
  the agent container self-cloned and **all 34 submodules materialized, zero
  skips** — the four UUID-keyed rows resolved too, which is exactly why the
  route returns ids and not names; `/projects/container/<id>/agents/available`
  answers 200 through the tunnel where it 502'd; and the launch path reaches
  the CREDENTIAL GATE (a "Claude sign-in" TERMINAL, /claude-home empty). That
  gate is the expected end state — no login was completed.
  Also shipped: cli-bootstrap `af1dfa6` generates BOTH qits-projects urls in
  the artifacts run-args. `QITS_PROJECTS_INTAKE_URL` was a live gap, not just
  bookkeeping — the image default dials localhost, so in the standalone
  deployment every push announced its backup to ITSELF.
  Rode along in the projects release: **`Project.slug` is UNIQUE now** (V6),
  reversing the recorded "deliberately non-unique" decision. A DERIVED slug
  auto-suffixes `-2`, `-3` (the caller stated nothing about the value); a
  SUPPLIED one that collides is a 409, because the slug names the upstream org
  the wrapper backs up to and a silent rename would point a project's backups
  somewhere nobody asked for. The `AgentContainers` label-ownership guard
  stays — its real reason is that deleting a project does not remove its agent
  container, so a later project taking the freed slug meets the old one.
  **The webui gitlink landmine bit again** and was caught before release: the
  first projects commit silently dragged `service/src/main/webui` back from
  `16eaabd` to `33745db` (`ignore = all` hides it). Check
  `git ls-tree <branch> service/src/main/webui` against main BEFORE every
  qits-projects release, not after.
  **Open from this workstream:** no re-provision path exists (the daemon
  latches `provisionStarted` for the process lifetime and `ensure` no-ops on a
  running container), so recovery is still remove-the-container-and-re-ensure;
  the SPA does not yet render `failureDetail` (additive backend field, the
  webui is its own repo).
  **Follow-ups recorded:** UUID repoIds remain on workspace-daemon,
  repositories, platform-dns, cli-bootstrap + the wrapper — no longer a
  blocker now that names resolve to ids, but the rows are still inconsistent
  (fix recipe in memory: bare-name repo first, DELETE rewrites the wrapper —
  revert needed);
  qits/workspace:latest builds ONLY from the retired monolith checkout
  (~/code/qits-backend-devel, --target workspace) — needs a home;
  project↔environment link unset in the deployments UI (env `prod` vs project
  slug `qits`, the stale name-join convention); repository backups all
  AUTH_REQUIRED (nobody signed in since the volume wipe); vertx-http-proxy
  breaks on h2c inbound (edge + workspaces proxy family); CaptureService's
  feature/<timestamp> branches collide with feature/<epic>/<feature>;
  services/qits-workspaces webui checkout 13 behind origin.

- **Deployable images (new concept)** (started 2026-08-08): docker images as
  deployable services — first case `images/qits-oci-postgresql`
  (SHIPPED: see day-end state above; design record follows).
  A repo holds a Dockerfile (FROM postgres:18.4) + `.config/qits`, and rides the
  NORMAL lifecycle: SCM release → CI image build → SoftwareRelease → the env's
  qits-deployments deploys it. PoC scope = behave like any Quarkus service
  deployment; proper configuration comes later.
  **Design settled after a four-explorer sweep** (findings in session history):
  - The build side needs NO platform change. CI steps are generic `{image,
    script}`; `images/qits-oci` is the in-tree precedent (Dockerfile-only repo,
    release pipeline, docker artifacts → SoftwareRelease). The repo carries
    `ci-post-receive.yml` (sha-tagged image, the tag the deployer resolves:
    `$QITS_REGISTRY/$QITS_IMAGE_REPOSITORY/<repo>:$QITS_CI_SHA`) and
    `ci-event-release.yml` (`artifacts: [{type: docker}]` → SoftwareRelease).
    Base images pull through the OCI mirror: `FROM localhost:8081/hub/library/postgres:18.4`.
  - The release side needs NO change: the flow is stack-agnostic ("a repository
    with no stack is still a release"); `deployments.yml` with
    `deploy_branches: environment/prod` makes the release promote the deploy ref,
    whose CI-hot push is what actually deploys.
  - The deploy side needs ONE change: the health gate is unconditional
    `curl -fsS http://localhost:8080<health_path>` (DockerDeploymentDriver:711),
    which no non-HTTP image can pass, and run-args cannot carry a quoted
    override. **New optional spec key `health_cmd`** (mutually exclusive with
    `health_path`; used verbatim as `--health-cmd`) in the strict
    DeploymentSpecParser + driver. Ordering: the deployer change must be LIVE
    before this repo's first deploy (unknown key = failed deployment; the
    workspaces reader is lenient, releases unaffected).
  - PoC accepts: no volume (data dies with the container), `POSTGRES_PASSWORD`
    baked as a placeholder in the Dockerfile; both go through the real
    config mechanism later (volumes/env stay deployer-side run-args by trust
    design). Consumers dial the wire alias `prod-qits-oci-postgresql:5432`;
    no gateway route (routes are a gateway enum; not needed for TCP peers).
  - Bootstrap: NOT added to PlatformModel DEPLOYABLES/SEEDED_REPOS — it enters
    the platform through the normal repo lifecycle after bootstrap settles.
  **Repo seeded and pushed** (`6dbfc60` on GitHub main): Dockerfile,
  .dockerignore, both CI pipelines (release extraction uses jq — allowed here,
  this repo is never in the bootstrap path), deployments.yml with `health_cmd:
  pg_isready -U postgres`, README.
  **Deployer `health_cmd` SHIPPED IN CODE** (qits-deployments `d552f1c`, main,
  LOCAL ONLY — not pushed): optional key, any non-blank one-line string ≤512
  chars (no charset allowlist — it IS the command, runs in the repo's own
  container, one argv element), mutually exclusive with `health_path`; carried
  spec→Target→Plan→StartSpec, deliberately NOT persisted (spec is re-read per
  deploy; the catalogue-resolving arm only records FAILED rows). `clean verify`
  green: 190 tests, 0 failures. Docs updated (README/AGENTS/spec header).
  Spot-checked by the orchestrator: seeded pipeline files match the CI schema;
  `QITS_CI_REPOSITORY_URL` confirmed injected (CiDaemonLauncher:508).
  **NEXT (blocked on the cold bootstrap settling):** release qits-deployments
  through the release endpoint (branch ahead of main + marker commit — NEVER a
  direct main push), push wrapper `aa271d4`, get qits-oci-postgresql onto the
  platform git host (reconcile adopts it from the wrapper), then prove the
  lifecycle: push → sha image → release → SoftwareRelease → deployment row
  ACTIVE with postgres passing `pg_isready`. Deploy ORDER: the health_cmd
  deployer must be live BEFORE this repo's first deploy (strict parser fails
  on the unknown key).

- **Maven Central proxy in qits-platform-artifacts: CODE COMPLETE, UNMERGED**
  (2026-08-08): a brainstorm about extracting the blob store exposed a gap —
  there was NO Maven proxying anywhere; CI's `.qits-maven-settings.xml` mirrors
  only `qits-maven`, so every step container pulls the whole Central tree from
  repo1.maven.org directly. Implemented on the npm-proxy blueprint, commit
  `7d1d488` on branch `feat/maven-central-proxy` in worktree
  `/home/wohlben/code/qits-maven-proxy-work/qits-platform-artifacts` (main
  checkout verified pristine — the bootstrap runs from it). Full `verify` green:
  611 tests, 0 failures. Landed: `RepositoryType.MAVEN_PROXY`, seeded repo
  `central` (repo's own recorded name, not `maven-central`); V13 migration
  (widened type check + `maven_proxy_metadata` table; cached files are ordinary
  `maven_artifact` rows, so census/explorer/GC needed no new liveness code);
  `MavenUpstream` miss path; metadata TTL PT1H with ETag AND Last-Modified
  revalidation (plain file-server mirrors have no ETag) + serve-stale; deploy to
  proxy = 405; GC cache strategy, window P90D (maven-packages' own resolve-
  cadence argument), identity = path not coordinate (a cache self-repairs, a
  publish doesn't — documented contrast in both adapters); config
  `qits.artifacts.maven.proxy.upstream` + `.metadata-ttl`. Worktree-only
  caveat: `service/src/main/webui` submodule was tar-copied from the main
  checkout (worktree add leaves it empty; not in the commit). Fixed in passing:
  `PackagedProcessIT` asserted 8 repo types against a 9-constant enum (native-
  only, never ran in verify) — now 10. Integration checklist (from the
  implementer): base is `9a0e5c0`; if another workstream lands first, check
  (a) V13 not taken — else renumber AND re-enumerate
  `ck_artifact_repository_type` from the merged `RepositoryType.values()`,
  (b) the type-count tests (`GcPlanControllerTest` 9→10, `PackagedProcessIT`
  8→10) as conflict sites, (c) merge the `GcTypeConfigTest` maven-proxy hunk,
  don't resolve it away. Deploy via the release endpoint, never a direct main
  push. Post-deploy smoke (suite has no network): `curl -sI
  <host>/artifacts/maven/central/org/slf4j/slf4j-api/2.0.13/slf4j-api-2.0.13.jar`
  → 200 with `Cache-Control: … immutable`, second call from the blob store.
  **NEXT (user-gated)**: merge to main +
  release (after the bootstrap settles), and the separate verdict on wiring CI
  through it (a `central` mirror in `.qits-maven-settings.xml` — behavior
  change across all builds, makes artifacts a hard dep of dependency
  resolution). The blob-extraction brainstorm itself is SHELVED (shared
  content-addressed store across envs; works, notes in session history).

- **Deployment unification: CODE COMPLETE, PRE-BOOTSTRAP** (2026-08-08): all of
  `deployment-unification-plan.md` phases 1-5 implemented by parallel subagents,
  every touched repo green on its own suite. Landed: qits-platform-edge (new
  service, host-header env demux, ws+SSE passthrough, native, platform target);
  deployer rework (aliases `<env>-qits-<app>` / bare platform names, container
  `qits-pd-<app>-<id8>` platform shape, platform branch matching via env rows,
  parser `deploy_branches` in / `branch:` out); workspaces spec-driven promotions
  (+quiet trunk pushes; no-spec repos promote nothing); specs in all deployables
  (`deploy_branches: environment/prod`; 4 platform targets: edge/idp/artifacts/
  docs); six submodule renames locally (wrapper plumbing verified); rename
  internals in artifacts/idp/deployments + both SPA chains; idp identity model
  (clients prod-qits-ci, qits-platform-artifacts, prod-qits-workspaces,
  prod-qits-gateway; +aud prod-qits-deployments; qits-cd dropped); gateway XFF
  multi-hop semantics (ws allow-list carry-across included) + CD retirement +
  defaultHost deletion; pipeline-file wire-name sweep (only live dials were
  ci/workspaces maven build-args; rest comments); platform-name defaults baked
  (incl. deployer's load-bearing git-host-url); bootstrap CLI prod rework
  (93 tests, native built: env default prod, one deploy ref, edge second-to-last
  before the deployer handoff, seed containers named by wire alias, volumes
  renamed, fail-loud sources, unwrap patterns widened). qits-platform-edge added
  as wrapper submodule. All repos pushed to GitHub (gateway rebased onto its two
  backup-synced release commits first). `unwrap --with-volumes` DONE (11
  containers, all volumes, 28 images — old world gone). COLD BOOTSTRAP IN
  PROGRESS, runs so far: 1+2 failed on qits-ci seed testCompile —
  MachineGuardTest used QitsClaims.CI/CD, constants deleted from
  qits-integrations-quarkus; local verify was green only because ~/.m2 served
  the OLD auth-core jar; the seed registry serves the new one (drift the
  clone-alone rule hides; fixed: test owns its audience literals, qits-ci
  4410b73, pushed). Run 3+4 + manual probe: quay.io unreachable from this host
  (TLS connection reset, multiple CDN IPs, plain curl too) — likely edge
  throttling after today's repeated image pulls; backoff probe retrying every
  5 min, bootstrap resumes when quay answers (seed stack through qits/ci is
  built and cached; unwrap deleted the mirrored builder images, so the daemon
  musl build MUST re-pull quay). History resets with the volumes — accepted.
  Cosmetic debt deferred: Maven artifactIds/application.name/output-name keep
  old names; spec headers still say "qits-platform-deployments" in prose.
  **The platform is LIVE as env prod** (2026-08-08): 12 applications deployed and
  healthy, and the bootstrap converges green (run 9, 45 phases, 5m33s).

- **Epic lifecycle + refinement agent harness** (2026-08-08, branch
  `epic-refinement`, worktree `~/code/qits-qits-epics`): plan + settled decisions
  in `epic-refinement-plan.md`. Wave 1 running in parallel: backend lifecycle
  (statuses REFINING/IMPLEMENTATION/SUPERSEDED/ABANDONED, V3 migration, freeze
  enforcement, transition endpoint with supersede-copy), SPA status-grouped
  overview (refining draft cards, collapsed done/superseded/abandoned,
  transition buttons), and the qits-projects-daemon skeleton (new submodule,
  copy-adapt of qits-workspace-daemon). **Landed so far** (all green, local
  commits): backend lifecycle `5dd4650` (note: a superseded epic's successor
  mints a fresh epic slug — the unique constraint forbids reuse), SPA grouping
  `9c64e22`, SPA SSE live-updates `5e988bf`, daemon skeleton `c5aba81..8f6d96b`
  (242 tests, trims recorded in its AGENTS.md), backend MCP tools + SSE
  `f1ce901` (landmine: @Transactional on dual-PU MCP tools wedges pooled
  connections — the tools are transaction-free by design, documented in-class).
  **All seven workstreams landed and browser-verified** (2026-08-08 afternoon):
  registry/proxy/tunnels `b74abaa..ac0de3c` (in service/…/agenthost/ — no domain
  aggregate owns a container here; vendored protocol module; findings:
  vertx-http-proxy breaks on h2c inbound — qits-workspaces has the same bug,
  own workstream; non-unique project slug guarded by label-ownership 409;
  docker startup gated to NORMAL launch mode) and the SPA terminal panel
  `7937d3c`+`33745db` (session resolution reads GET /commands — the lineage
  tree can't tell running from exited; sign-in PTY recognition kept).
  Browser-verified against the packaged jar + ng serve: grouped sections,
  refining draft card, UI transitions (refining→implementation moved the card
  and minted branch names), supersede successor slug `-2`, freeze 409, SSE
  live update (curl-added feature appeared without reload), agent panel
  dormant row. Screenshot delivered in-session.
  **ROLLED OUT ON THE LIVE PLATFORM** (2026-08-08 evening). Released:
  qits-projects `2026.808.151631` then `2026.808.152415` (the webui bump the
  spa-projects train cut), qits-spa-projects `2026.808.152119`.
  qits-projects-daemon is on GitHub and on the git host (`8f6d96b`, no release —
  it publishes no artifact yet). Three images built locally, none pushed to a
  registry, because workspace-launched containers use the host daemon:
  `qits/workspace:latest`, `qits/projects-daemon:latest`,
  `qits/project-agent:native`. Two gaps found and closed on the way — the
  runtime image had no docker CLI (`DockerAgentRuntime` shells it) and the
  deployment had no docker socket; both fixed, and an agent container really
  starts now.
  **Where the workspace toolchain image comes from, because nothing in this
  repository says**: it is the pre-split monolith's `workspace` stage, still only
  at `/home/wohlben/code/qits-backend-devel/docker/qits/Dockerfile` —
  `docker build -t qits/workspace:latest --target workspace -f docker/qits/Dockerfile .`
  from that checkout. Three Dockerfile headers here point at it and call it
  `workspace-base`, which is not its name. The monolith is otherwise retired, so
  this recipe needs a home: without that checkout no project agent and no
  workspace can be built at all.
  **Open:**
  - **The agent container cannot reach its host — stale wire names.**
    `AgentContainerFactory` defaults `qits.projects.own-host=qits-projects` and
    `qits.projects.agent-git-base=http://qits-artifacts:8080/artifacts/git`, both
    pre-rename. On qits-net the names are `prod-qits-projects` and
    `qits-platform-artifacts`, so the daemon boots, binds its hook webhook and
    then blocks forever on a DNS lookup of its control socket. Same stale-plane
    family the unification sweep chased; the fix is two run-args
    (`QITS_PROJECTS_OWN_HOST`, `QITS_PROJECTS_AGENT_GIT_BASE`) or better
    defaults. Until then the harness is inert.
  - The agent-container e2e beyond "it starts": self-clone, the reverse tunnel,
    and the refinement chat against a real agent are unproven live.

- **Deployment re-model brainstorm** (started 2026-08-08): `deployment-model-draft.md`
  in this repo. Section 1 (the lifecycle today: release → refs → build → deploy, the
  bus, the self-hosting knot) is written. Section 2's current sketch (after three
  superseded iterations, all recorded in the doc: platform plane gateway+idp, then
  +observability + admission test, then per-env idps with an issuer hierarchy —
  dropped as too many cans of worms; then per-env artifacts with a cache
  hierarchy — dropped as bloat): **every env runs the same full stack;
  "qits-platform" IS production; a platform service = an application deployed ONLY
  into prod, its REPO named `qits-platform-<x>` and dialed by that name unprefixed
  (singletons need no instance qualifier; env services are `<env>-qits-<app>`),
  joined to every env's networks. Exactly
  FIVE: qits-platform-edge + qits-platform-idp + qits-platform-artifacts +
  qits-platform-docs (the docs reader follows its store: a per-env reader = three
  front doors onto one store) + qits-platform-dns (one zone authority, names the
  envs, host :53 — deployment stays out of the MVP).** The bar: per-env copies
  cannot do the job (one port, one trust root, one zone authority) OR would
  multiply heavy shared-by-nature state for no isolation gain (the store and its
  views). The
  edge routes UNIFORMLY by host name — apex qits.eu → prod-qits-gateway exactly
  like `*.dev.$domain` → dev-qits-gateway (matches qits-dns's model); route table
  = env list, knows no app names. Idp: ONE issuer for all envs; env isolation
  lives in the TOKEN MODEL — env-qualified client ids + audiences (`dev-qits-ci`,
  `aud=dev-qits-deployments`); `aud=platform-…` is the normal way envs reach
  platform services (`aud=qits-platform-artifacts`); a dev secret cannot mint
  prod-valid tokens. Accepted cost:
  idp changes cannot be staged in an env — idp must stay maximally boring.
  Artifacts (user decision, supersedes the earlier no-cut/hierarchy verdict):
  ONE store, unsplit — git host, registries, proxy caches, blobs, docs for every
  env; promotion collapses (built once, visible everywhere, "promote" = deploy
  that sha); the GC becomes MULTI-DEPLOYMENTS AWARE — keep = UNION of every
  env's pins (each env's deployments + ci, endpoints via injected config),
  fail-closed across ALL sources (one dead env blocks GC platform-wide,
  accepted); it is the one platform service that calls INTO envs (periodic,
  read-only). Remaining prod role: BOOTSTRAP ORIGIN (CLI boots prod; prod
  creates + first-deploys the other envs). Observability per-env; platform
  services export to prod's sink. Naming (settled): qualified names EVERYWHERE
  on the wire (`<env>-qits-<app>` / `qits-platform-<app>`); images stay
  env-agnostic (peer names only via deployer-injected config — the invariant to
  protect). Swarm fits (stack-per-env naming for env services, platform services
  as plain swarm services under their repo names, VIP cutover; no L7 host
  routing — edge stays; reshape cost: deployer's docker-run/aliasHolders →
  `service update`). Envs (settled): three, fixed —
  dev/preprod/prod; NOT epic-scoped (maybe later). Open: lifecycle re-wiring
  around the one store (post-receive fan-out per ref → which env's ci; who owns
  `main` builds; per-env bus vs one store), promotion remainder (where "release
  to prod" runs; rebuild vs reuse across deploy refs), env-creation choreography
  (idp grants, stack, DNS, connecting the platform services + GC pin
  endpoints), prod's self-hosting knot (contained, not dissolved). Draft by
  declaration — iterate, don't obey it.
  **Implementation plan APPROVED in its decisions** (user, 2026-08-08):
  `deployment-unification-plan.md` — 7 phases to a clean cold bootstrap in the
  target shape, MVP = ONE env named **prod** (no second env). Decisions D1–D5:
  D1 retire `platform/main` (deploy refs = `environment/<env>` only; platform =
  qits-platform-* repo name + prod-only + all-nets flag; fixes the stale-plane
  release bugs by reading refs from the repo's deployments spec). D2 the edge =
  new repo `services/qits-platform-edge` — CREATED on GitHub 2026-08-08, verified:
  has `main` + initial commit (submodule add works directly). D3 repo naming:
  platform repos = `qits-platform-<x>`, env repos plain. **GitHub renames DONE
  (user, 2026-08-08), VERIFIED via ls-remote**: platform-deployments→deployments,
  platform-spa-deployments→spa-deployments (the `qits--spa-deployments` double
  dash was a message typo, real name correct), artifacts→platform-artifacts,
  idp→platform-idp, dns→platform-dns, spa-artifacts→platform-spa-artifacts;
  docs + spa-docs were already right. Local wrapper-submodule renames = phase 4
  (GitHub redirects cover old-name remotes meanwhile). Leftover: `platform/main`
  branches still on GitHub for platform-artifacts/platform-idp/deployments —
  delete in phase 3 (D1). D4 no swarm in this
  plan. D5 GC ships UNCHANGED in the MVP (single pin-source pair, new URLs only);
  the multi-deployments reshape is deferred with a HARD GATE: must land BEFORE
  any second env exists (else that env's pins are invisible → over-deletion).
  Phases: 1 config plumbing (hardcoded-peer audit, deployer naming scheme +
  injected qualified names) → 2 the edge (gateway sheds :8080; browser pass incl.
  websockets/SSE is the gate) → 3 refs/release flow → 4 renames → 5 bootstrap CLI
  (default env `prod`, qualified idp clients/audiences) → 6 THE CLEAN BOOTSTRAP
  (unwrap --with-volumes; 12 containers; verification checklist in the plan;
  history resets) → 7 deferred (GC multi-pin GATE, second env, multi-env wiring,
  swarm, dns).

- **Epics overview on the project detail page** (2026-08-08). **Released and live**:
  qits-spa-projects 2026.808.105044, qits-projects 2026.808.110015; container on the
  release sha, deployment row ACTIVE, live page verified in the browser (empty state —
  live has no epics yet). The releasing itself: the SPA release auto-triggered the
  `maintenance/qits-spa-projects` follow-bump in qits-projects, so a manual webui
  gitlink bump is redundant — reconcile onto the moved main and release only the code.
  - Backend: immutable git-safe `slug` on Epic/Feature/Task — V2 migration (backfill +
    per-scope dedupe), `Slugs.java`, DTOs, openapi. H2 note: `regexp_replace` takes no
    `g` flag.
  - SPA: read-only epic→feature→task tree on the project page — client-side fan-out,
    status badges from `implementedOn`/`implementedAt`, compare links are muted
    placeholders (no compare UI exists yet).
  - **Branch naming convention adopted** (per-level prefixes, no path-prefix conflicts):
    `epic/<epic>`, `feature/<epic>/<feature>`, `task/<epic>/<feature>/<task>`.
    Documented in qits-projects AGENTS.md ("Branch naming").
  **Open:**
  - qits-workspaces CaptureService mints `feature/<timestamp>` capture branches that
    collide directory-wise with the new feature branches — needs a new prefix,
    separate workstream.
  - Compare/commits view to replace the placeholders; epic-level implemented state for
    zero-feature epics (Epic has no implemented field, so those can only show "open").
  - quarkus:dev in qits-projects transparently reads PRODUCTION: Quinoa's dev proxy
    matches ignored-path-prefixes (`/api,/q,/mcp`) against the RAW path, so with
    `ui-root-path=/projects` every GET under `/projects/api` misses the ignore list,
    goes to the Quinoa-spawned `ng serve`, whose `proxy.conf.json` (wired via
    angular.json) targets `localhost:8080` — the live gateway. Live 404s fall through
    to local REST; non-GETs skip Quinoa — hence "reads live, writes 404" (writes only
    saw the local DB, which lacks the live ids). Fix candidates: point webui
    `proxy.conf.json` at the dev backend, or add the full-path forms to the ignore
    list for the dev proxy (prod matches them ui-root-relative — both spellings would
    be needed). Until fixed: verify with the packaged jar
    (`-Dqits.startup-seed.enabled=false`).

- **The platform runs on native docker-ce in the Fedora distro** (since 2026-08-08).
  Docker Desktop is uninstalled; the daemon is systemd-managed and a single-node swarm
  manager (the deployer can target swarm services later without re-plumbing); containers
  bind the real `/var/run/docker.sock`; an HKCU Run key (`qits-wsl-fedora-autostart`)
  starts the distro at Windows logon. Rebuilt by cold `./qits-local-up.sh` bootstrap —
  the how and the six bugs it surfaced are in this repo's and qits-cli-bootstrap's
  2026-08-08 commit messages.
  **Open:**
  - Prove a full host reboot end to end (dockerd + restart policies + Run key say yes;
    nobody has watched it happen).
  - qits-cli-bootstrap: a failed clone refresh must fail LOUD — stale clones with dead
    origins (pre-`libs/`-move paths) built Aug 2 sources silently until the version pins
    caught it.
  - Push the local commits: wrapper (handoff, shim fix) and qits-cli-bootstrap
    (`415ca8a`, `1ed351e`).
  - **The release flow still thinks the gateway is an environment service**: releasing
    qits-gateway (2026.808.94038) promoted `environment/dev` beside `platform/main`,
    re-creating the deleted branch (deleted again by hand). Same stale-plane bug family
    the bootstrap CLI had — qits-workspaces should read the plane from the repo's
    deployments spec, not assume both branches.
  - **The release flow pushes every promoted ref CI-hot**: one release queued four
    overlapping runs of one sha (`main` ×2, `platform/main`, `environment/dev`) — the
    image-tag collision the bootstrap avoids with `-o qits.no-ci` on the quiet refs. All
    four happened to pass; the flow should push non-deploy refs quietly.

- **The platform plane is readable, and the gateway is on it** (2026-08-07, late). **Shipped and
  verified live** — eleven containers healthy, every gateway route 200, both planes screenshotted.
  Two changes that turned out to be one question: "why does the Deployments page show three
  applications when eleven are running?"
  - `GET /deployments` takes a required `environmentId`, so the plane that has **no** environment id
    could not be asked for at all — every platform row was recorded and then unreadable. It now
    accepts `?environmentId=platform`, the stand-in `ApplicationKeys` already puts at the front of a
    platform application's id. It cannot be mistaken for a tier (an environment id is a random
    UUID), and it is a named plane rather than a widening: no filter is still a 400.
  - qits-platform-spa-deployments grew a third root, **Platform services**, beside the projects and
    the unmatched-environments bucket. `loadEnvironment` became `loadPlane`: one branch (which
    listing holds the applications — the environment aggregate, or the flat `GET /applications`) and
    one pair of caches keyed by an environment id *or* the word `platform`. The bucket starts
    **closed** — the unmatched bucket is free because its contents arrive with the page, this one
    costs the same two requests as any other expansion.
  - **qits-gateway is a PLATFORM service now.** It publishes the host's only port and every
    environment is reached through that one origin, so a per-tier copy was always a second binder
    for port 8080. `available_on_env` went with the flip: it made the gateway an environment's
    public node, and a platform service joins every environment's per-application networks
    unconditionally — the only thing left behind is the bundle network, whose only member was the
    gateway itself. Verified: the new container holds `qits-platform`, `qits-net` and all three
    `qits-env-dev-*` networks.

  Things worth not rediscovering:
  - **environment → platform is a supported one-way conversion, and it is complete on the DB side.**
    `registerPlatform` drops the links *and* absorbs every environment-scoped deployment row —
    ACTIVE becomes DECOMMISSIONED and `environment_id` is nulled, so the tier's history moves into
    the plane rather than being orphaned. Nothing had to be fixed by hand. The reverse is a 409.
  - **What the conversion does NOT do is stop the old container**, and that is the whole operational
    catch. `predecessorsOf` keeps an alias holder only when its `qits.platform.deployments.environment`
    label is absent or equals this deployment's — and a platform deployment's is null. So the
    tier-labelled gateway was invisible to the cutover; left alone it would have held port 8080 and
    the successor's `docker run` would simply have failed. **Delete the old container before
    promoting.**
  - **`aliasHolders` uses `docker ps -q`, not `-a`** — stopping a predecessor is enough to hide it
    from the cutover, which is what makes "stop, deploy, remove" a safe order if you want a rollback
    in hand.
  - **The git host is reachable directly on `localhost:8081`** (`http://localhost:8081/artifacts/git/<repo>`),
    which is how you push while the gateway is down. CI and the deployer never need the gateway
    either: the CI step clones `qits-artifacts:8080` and the deployer pulls `localhost:8081`.
  - **`run-args` are keyed by application name, not by plane**, so `-p 8080:8080` survived the flip
    untouched. They live in `/work/config/application.properties` on the deployer's config volume —
    not in its env, which is where you will look first.
  - Push `main`, wait for green, *then* push `platform/main`: two runs of one sha collide on the
    shared image tag when they overlap, and sequential costs one cached rebuild.

  qits-gateway's `environment/dev` branch is **deleted** on the git host — the repo now carries
  `main` and `platform/main` only, both at the deployed sha. Its tip was already an ancestor of
  `main`, so no commit was orphaned, and the delete triggered no build.

  **Left open:** the page draws project `qits` as **"no environment"**
  and puts `dev` in the unmatched bucket: the join is `environment.name === project.slug`, and since
  the env re-model the environment is named `dev` while the only project's slug is `qits`. That
  convention is stale, and it predates all of this.

- **Sync targets + automatic GitHub backup** (2026-08-07, follow-on to the wrapper work).
  **SHIPPED AND VERIFIED LIVE.** `Repository.url` is formally the backup sync target now:
  `RepositoryDto.backupUrl` ships beside a wire-deprecated `url` twin (drop it next release —
  tracked), the reconcile derives every member's target relationally (wrapper's backup
  sibling via the relative `.gitmodules` url) and healed all 32 rows to the org namespace,
  and the UI cards say **Clone** (always the platform host's name-addressed url) and
  **Backup** — the "Origin" label is dead. Backups are automatic: the git host fans its
  post-receive out to `POST /projects/api/events/post-receive` (`-o qits.no-ci` does NOT
  suppress it), qits-projects debounces per repo and pushes `refs/heads/* refs/tags/*` to
  the target; an hourly sweep (`qits.projects.backup.enabled`) covers what events miss.
  UI restructure per user: `:projectId` is a lean overview (heading + "Project setup"
  action); everything else moved to `:projectId/project-setup`; every visible "wrapper"
  became **Project repository** ("wrapper" stays informal).
  **Late-day corrections (2026-08-07 evening), all shipped:**
  - **Release-flow correction (user-called):** direct main/platform-main pushes deploy code
    but skip the real release flow. Everything from earlier today was squared with catch-up
    releases through `POST /workspaces/api/branches/release?repositoryId=…` `{branch,summary}`
    (needs the branch AHEAD of main — an empty marker commit works; the flow stamps
    `release(<version>)`, publishes SCMRelease, promotes environment/dev + platform/main
    itself). All six touched repos got stamped versions. NEVER push main directly again.
  - **SIGHUP crash (the 502s):** using the sign-in terminal killed the service — ProcessBuilder
    file redirects open in the PARENT with no O_NOCTTY, and a PID-1 session leader adopting
    the pty slave gets the kernel's SIGHUP on teardown; Quarkus treats HUP as stop. Fixed by
    opening the slave in the child (`sh -c 'exec 0<>"$0" …' <slave> setsid --ctty git …`) plus
    a log-and-ignore HUP handler. Regression test reproduces the exact signature.
    Adds /bin/sh to runtime requirements (UBI9-minimal has it).
  - **Gitlink landmine, again:** the SIGHUP-fix commit silently dragged the webui gitlink
    backwards (ignore=all hides it; the UI "reverted"). Restored. Check `git ls-tree` before
    releasing qits-projects from a worktree.
  - **Terminal paste:** the pane had no paste listener. Now a hidden-textarea capture
    (xterm.js pattern) — Ctrl+V/Cmd+V/Shift+Insert send one data message. Chromium-measured.
  - **Release D shipped:** `RepositoryDto.url` is gone; `backupUrl` is the only spelling;
    ci/workspaces SPAs dropped their declarations too.
  - **The spa-projects release train is real:** releasing qits-spa-projects fires
    `ci-event-upstream-spa-projects.yml` in qits-projects, which force-pushes
    `maintenance/qits-spa-projects` and cuts the webui-bump release itself — do NOT bump the
    gitlink by hand for SPA-only changes; the train races you (it won today, harmlessly).
  **The sign-in now lives in the UI**: the project-setup page has a Backups panel —
  per-card badges from `RepositoryDto.lastBackup` (V5 records every attempt's outcome),
  "Sync backups" (project-wide `POST …/repositories/backup-sync`, 202), and "Sign in to
  backup remote", an inline terminal driving the remote-login PTY websocket (client sends
  JSON `{type:data|resize}`, server sends raw PTY text; close 1000 = refetch; the session
  lingers 60s server-side so closing the pane mid-prompt is safe). One sign-in against
  github.com fixes every repository — the credential store is host-keyed.
  **Still pending a human: nobody has signed in yet — all 32 rows sit at AUTH_REQUIRED.** Things worth not rediscovering:
  - The deployer reads `/work/config/application.properties` at ITS boot, not per deploy —
    a run-args edit needs `docker restart` of the deployer before the next roll picks it up.
    (`QITS_PROJECTS_INTAKE_URL` was added to the qits-artifacts run-args there.)
  - Do not promote qits-artifacts and anything else to `platform/main` concurrently: the
    artifacts cutover kills the other build's registry pulls at `localhost:8081` mid-run.
  - spa-ci/spa-workspaces read `name`/`backupUrl` now; the ci tree label no longer
    basename-hacks the url.

- **Wrapper repository as a first-class concept + projects UI** (2026-08-07). **SHIPPED AND
  VERIFIED LIVE — both releases.** Release A (+A.1 drift-healing) and release B are deployed
  (`qits-pd-platform-qits-projects-34098d66`); the real qits-qits history was force-pushed
  onto the platform wrapper origin (replacing the greenfield skeleton); the reconcile
  converged: 32 rows = wrapper + 31 components, archetypes directory-derived
  (13 SERVICE, 2 DAEMON, 5 LIBRARY, 9 FRONTEND, 1 CLI, 1 IMAGE), legacy fixture rows
  deregistered, all 31 wrapper entries matched, re-running reconcile is a KEPT×31 no-op.
  The projects UI is live at `/projects/` (auto-select, picker sub-nav, type groups,
  wrapper "in sync" + reconcile button) — screenshotted. **qits-backend (the pre-split
  monolith) is fully removed**: row deleted over REST, seed entry deleted in release B;
  a straggler deployment's row simply gets deregistered by its first reconcile.
  Four origins were preseeded onto the git host so reconcile could adopt them:
  qits-workspace-daemon, qits-repositories, qits-dns, qits-cli-bootstrap.
  Things worth not rediscovering:
  - The wrapper row's backup url was the stale `wohlben/qits-qits` fork; A.1's self-seed now
    asserts manifest archetype+url onto existing rows (two-pass, shared transaction — both
    load-bearing, see SelfSeedService comments) and the manifest constant is the org url.
    Other adopted rows still carry historic urls (e.g. `wohlben/qits-gateway`) — cosmetic,
    they are backup remotes only.
  - An empty wrapper `.gitmodules` disables the membership guard and deregistration until
    the first entry exists.
  - Worktrees under `/home/wohlben/code/qits-wrapper-work/` still exist; every branch is
    merged — prune with `git worktree remove` + `git branch -d` at leisure.
  Old text follows for reference. Plan:
  `~/.claude/plans/lets-start-by-planning-valiant-dragon.md`. Branch `feat/wrapper-first-class`
  in worktrees under `/home/wohlben/code/qits-wrapper-work/` (qits-projects, qits-spa-projects,
  qits-spa-ci, qits-spa-workspaces, qits-qits, qits-cli-bootstrap); main checkouts untouched.
  What landed: (A) qits-projects release A — archetypes SERVICE/DAEMON/LIBRARY/FRONTEND/CLI/
  IMAGE (+ deprecated INTEGRATION/APPLICATION aliases, widening-only V3), server-side wrapper
  commits (`amendTree` + `WrapperGitmodules` + `WrapperSubmoduleWriter`), create = url XOR
  name (blank repos seeded from new `repository-template/`), wrapper-driven reconcile +
  `POST .../repositories/reconcile` + wrapper block on the repositories list, membership
  guard on write paths, submodule import surface deleted, self-seed reads the wrapper (
  `platformManifest()` deleted), `RepositoryDto.name`; full verify + PackagedSurfaceIT green,
  native binary built and boot-checked. (B) archetype unions widened in ci/workspaces SPAs.
  (C) qits-spa-projects fully built (sub-nav picker, six type groups, wrapper status +
  reconcile report, create page; 69 tests green) and verified against the committed
  openapi.yml. (D) qits-qits: all 31 `.gitmodules` urls now relative `../<name>.git`,
  `integrations/*` moved to `libs/*`, docs updated; CLI `repoPath` follows; resolution
  smoke-tested against both a local and the GitHub origin.
  Empty-manifest semantics: a wrapper with no `.gitmodules` entries disables the membership
  guard and deregistration until the first entry exists (deploy-day safety).
  **Next steps, in order**: review diffs → merge each worktree branch to its repo's main →
  push through the platform git host → deploy release A → deploy the wrapper bump (after A)
  → run the repositories reconcile once → then release B (V4: row updates, qits-backend→FORK,
  tighten constraint, drop `repository_submodule`; delete deprecated enum constants; drop
  legacy union arms in the three SPAs). First reconcile will deregister the legacy
  fixture-sibling rows (testing-repo etc.) — expected; host repos survive.

- **The navigation is the gateway's answer now, and the sidebar has a sub-menu**
  (2026-08-07, late). **Shipped and verified on the live platform** — all eleven containers
  healthy, every gateway route 200, and the reading room screenshotted with ONE left column.
  Two things at once, because they are the same shape.
  `QITS_NAV_LINKS` — eight `{label, href}` entries compiled into a published npm package —
  is **deleted**. qits-gateway answers `GET /main-navigation` from its own `RouteTable`, so a
  component appears in the menu exactly when this gateway routes it, and `QitsMainLayout`
  fetches it through `provideQitsNavigation()`. `QitsService` now carries display identity
  (label + position) beside routing identity; **no label means no menu entry**, which is how
  `stt` (no SPA) and `cd` (superseded) stay out. `/v2` is excluded by construction — it is a
  protocol root docker hardcodes, not a page. `Home` is prepended: the landing SPA is the
  gateway's own static output and is in no route table.
  Underneath the *active* entry the layout renders a **sub-menu slot** — a `TemplateRef`
  handed sideways through the injector, because `QitsMainLayout` is a route component and
  nothing can be projected up into it. `qits-platform-spa-docs` is the only consumer: its
  second left column is **gone**, and the catalog tree plus the version picker live in the
  sub-menu instead. `scope.ts` is deleted (the tree *is* the scope→site list), `scopes.ts` is
  a landing page, and the reader is the iframe alone.
  Things worth not rediscovering:
  - **A caret range cannot pin a prerelease.** All nine SPAs pin
    `2026.806.184725-main.gc03ad30` **exactly**. `^2026.806.184725-main.gc03ad30` also admits
    the plain `2026.806.184725`, which npm prefers because it sorts higher — and that release
    predates `QitsPicker`, `QitsNavSubmenu` and `provideQitsNavigation()`. It installs
    silently and the build dies on "has no exported member 'QitsPicker'". The old
    `^…-main.g404b2c4` pin only worked because the stable release did not exist yet.
  - **`ci-event-upstream-ui-components.yml` in eight SPAs follows a `SoftwareRelease` of
    @qits/ui-components** and force-pushes a bump onto `maintenance/qits-spa-ui-components`.
    Releasing the library mid-change would have stampeded a nine-repo train over half-finished
    code, so **no formal release was cut** — the prerelease pin is deliberate, and a release
    plus its cascade is a separate later step.
  - **`git diff --cached --quiet` reports clean for a moved gitlink** under `ignore = all`,
    so a "did anything stage?" guard silently skips every submodule bump. `git status --short
    --ignore-submodules=none` shows the truth; so does `--ignore-submodules=none` on the diff.
  - **`QitsNavSubmenu` must be declared in the app SHELL**, beside the `<router-outlet />`,
    never inside a page: `RouterOutlet` rebuilds a page on every hop, so a declaration there
    loses the tree's scroll position and open groups each time a document is opened.
  - The slot is a **stack, not a slot** — two pages are alive at once during a hop, and a
    single nullable field lets whichever is destroyed last clear a template still on screen.
  - `.qits-layout-nav` needed `min-height: 0`: a grid item defaults to `min-height: auto`, so
    a tall sub-menu grows the row instead of scrolling and the sidebar runs off the viewport.
  - The **gateway ships twice** — once for `/main-navigation`, once for the home SPA gitlink.
    Its `src/main/webui` is a second checkout of qits-spa-home and was three months stale
    (`@qits/ui-components@^0.0.4`); missing it is how this cascade half-lands invisibly.
  - Multi-module services carry the client at `service/src/main/webui`; only qits-gateway and
    qits-platform-docs use `src/main/webui`.

  Proved in a browser, not inferred: clicking a site in the tree and picking a version are both
  **router hops** — a marker set on `window` before the click survives both, which is what says
  the shell (and with it the tree's scroll position) was never rebuilt. `window.location.assign`
  is gone from `onVersion`. Back leaves the versioned URL for the unversioned one rather than
  walking the frame's own history. The iframe is version-addressed, never the bare
  `/platform-docs/<site>` — that path is the service's redirect *to the reader*, and pointing the
  frame at it renders the page inside itself. Below 768px the burger reveals the nav with the
  sub-menu inside it. No console error, no page error, no failed request on any SPA.

  **The release train then ran, end to end** (`@qits/ui-components@2026.807.122825`). npm
  `latest` moved off the pre-picker build, a real Storybook bundle joined `0.0.0-smoke` in the
  docs store, and every SPA came off its exact prerelease pin onto an ordinary `^` range. All
  nine services are current against their deploy branches and all eleven containers healthy.
  Switching versions is proved across two real versions now: the URL and the iframe both
  change, a `window` marker survives, and the tree keeps its state.
  - **`POST /workspaces/api/branches/release` is the door, and it refuses a branch already
    merged.** Work pushed straight to `main` via the escape hatch therefore cannot be released
    from where it landed — the release only moves forward from a branch carrying a commit
    `main` does not have. The CalVer stamp rides along, so that commit can be small.
  - **The double-build races are systemic, not luck.** A release promotes to `main`,
    `environment/dev` *and* `platform/main`, so three or four builds of one commit hit one
    docker daemon and collide on the shared image tag. Three forms appeared in one train:
    `No such image` at a COPY, `AlreadyExists` on tag create, and `tag does not exist` on push.
    Two hit a deploying branch (qits-ci, qits-observability); in both the image was already
    present and complete, so the fix was a **build-succeeded replay, not a rebuild**. This is
    the open follow-up "spec-aware release promotion" with evidence attached.
  - **The replay needs a token minted as the `qits-ci` client, not `qits-artifacts`.** The
    deployer wants audience `qits-platform-deployments`; the `qits-artifacts` client is granted
    `qits-ci, qits-cd, qits-artifacts, qits-workspaces, qits-gateway` and gets a flat 401. Its
    idp registration was never updated after the cd merge-back. `qits-ci` carries the audience.
  - **The train pushes to the platform git host only** — GitHub was behind on sixteen repos
    afterwards and had to be synced by hand. Beware `git ls-remote <url> main`: it can match
    more than one ref, and the resulting two-line "sha" makes every later git command fail in a
    way that reads as "not a fast-forward". Ask for `refs/heads/main`.
  - The deploy order that matters if this is ever repeated: **gateway first** (a library that
    ships before `/main-navigation` exists collapses every SPA's chrome to a single `/` link at
    once — there is no version negotiation), then the library, then the SPAs, then the webui
    gitlinks. qits-artifacts, qits-ci and qits-platform-deployments each went **alone against an
    empty queue**: they host the registry and git host, build everything, and deploy everything
    respectively.

- **Documentation is a published artifact** (2026-08-07). A `docs` repository type in
  qits-artifacts holds one immutable bundle per version at
  `/artifacts/docs/docs/<site>/-/<version>`; a release pipeline declares `{type: docs}` beside
  its package; `qits-platform-docs` is the reading surface at `/platform-docs`. The store
  answers what exists, the reader answers what to read.
  **Shipped and verified on the live platform**: qits-artifacts is deployed on `18c1128` and a
  real 9.7 MB Storybook bundle publishes (201, 53 files) and serves back through it;
  qits-gateway is deployed on `cf2129b` with the `/platform-docs` route; qits-ci is deployed on
  `9bd8726`, so the `docs` artifact type and `$QITS_DOCS_URL` are live and a release pipeline can
  now declare documentation. All ten platform containers healthy after the three rollovers.
  **qits-platform-docs is deployed and serving**: `/platform-docs/@qits/ui-components/` answers
  302 to the newest version and renders the workbench through the gateway, with no failed request
  and no page error. Its own reading is proved separately on qits-net, so the redirect is this
  service resolving `latest` from the store's rows rather than the gateway's landing page
  answering 200 — a distinction that cost a false "ready" reading earlier and is worth checking
  the BODY for, never the status code alone.
  **The reading room** (2026-08-07, later; **restructured the same night** — see the navigation
  entry above, which supersedes the layout described here). It had three layers: `/platform-docs/`
  listed what publishes documentation by scope, `/platform-docs/@qits` listed what that scope
  publishes, and `/platform-docs/read/<site>/-/<version>` showed one bundle with a **QitsPicker**
  beside it. The middle layer is **gone** — `scope.ts` is deleted and the `:scope` route with it,
  because the sub-menu's catalog tree *is* the scope→site list and two implementations of it fed
  by the same `catalog()` could disagree. `/platform-docs/` is now a landing page, the reader is
  the iframe alone, and the picker lives in the platform sidebar. The service still falls through
  for a single `@`-prefixed segment so a scope page could be served; nothing claims it now, and
  `DocsPaths.NOT_RESERVED` still reserves `read/`. `qits-platform-spa-docs` is the client,
  Quinoa-served from qits-platform-docs; the store gained `GET /artifacts/docs/<repo>` (the catalog
  it could not previously be asked) and the reader gained `/api/sites` and `/api/versions`.
  Three things in there are worth not rediscovering:
  - **`DocsRoutes.ROUTE_ORDER` is 20 000 and the client does not render without it.** Quinoa
    registers static resources at 1060 and its SPA fallback near 40 000. Below 1060, `SITE` claims
    the client's own `main-<hash>.js` — one alphanumeric segment, a perfectly good site name — asks
    the store for its versions and answers 404: the index renders and every asset is gone. Both
    Quinoa numbers are read off the jar and are not API.
  - **`route.url` under a `read/**` route includes the literal `read` segment.** Leaving it in made
    the site `read/@qits/ui-components`, which pointed the iframe back at the reader — five nested
    rails in a screenshot before it was caught.
  - **Every SPA now pins a prerelease of @qits/ui-components**, not `latest` — all nine at
    `2026.806.184725-main.gc03ad30`, exactly, no caret. A ui-components release turns those back
    into ordinary ranges. Was one client on the `main` dist-tag; it is all of them now.

  Two pieces of platform state are hand-made and want a bootstrap run to become generated:
  - **The gateway's `QITS_GATEWAY_PROXY_HOSTS_PLATFORM_DOCS` entry was appended by hand** to
    `/work/config/application.properties` on the qits-platform-deployments-config volume, and the
    deployer was restarted to read it. `cli/qits-cli-bootstrap` now generates that line, so the
    next bootstrap regenerates the file identically rather than diverging — but until one runs,
    that volume is edited state.
  - **qits-platform-docs is not registered in qits-projects.** `POST
    /projects/api/projects/{id}/repositories` assigns a **UUID** id, and
    qits-platform-deployments derives the image name from the repoId — so it looked for
    `qits/1adb8e08-…:<sha>` and reported `IMAGE_MISSING` while CI had pushed
    `qits/qits-platform-docs:<sha>`. Fixed by creating the repo on the git host under its bare
    name (`PUT /artifacts/git/qits-platform-docs`, body `{"defaultBranch":"main"}`) and pushing
    there; the two UUID rows were then deleted rather than left pointing at an id nothing uses.
    **The underlying mismatch is unfixed** — either the projects API should let a caller choose
    the id, or the deployer should resolve the image from the application name.
  - `@qits/ui-components@0.0.0-smoke` is a **hand-published docs version in the live store** from
    verification. Harmless — it dedupes against the real one and the own engine ages it out — but
    it came from no release, and it is currently what `latest` resolves to.
  - The docs half of a ui-components release only fires on `SCMRelease`; a push to `main`
    publishes the npm prerelease and no docs version, by design.
  Three build failures on the way, each a real gap now closed: a non-exhaustive `switch` over
  `RepositoryType` that local incremental compilation hid, a `./mvnw` line in a step container
  that has no JDK, and `quarkus.package.output-name` without its
  `jar.add-runner-suffix=false` twin. The last is now on the checklist in
  `docs/project-setup-quinoa-angular.md`, which mentioned neither key.

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

2. **The `qits-spa-cd` → `qits-platform-spa-deployments` rename is COMMITTED and pushed**
   (2026-08-07). The client repo is `7543720`, qits-platform-deployments `4271a2a`, the
   bootstrap `85ad5f5`, and this repository carries the submodule at
   `frontends/qits-platform-spa-deployments`. The Angular project key and
   `quarkus.quinoa.build-dir` moved together, as they had to; `docker/Dockerfile`'s
   `RUN d=…/dist/<name>/browser` guard is the third spelling of that path and moved with them.
   The rename was cut from `61986bf`, a release behind, and is **rebased onto `48cf39d`**
   (`2026.807.122943`) — so GitHub is no longer a release behind, and the released
   `^2026.807.122825` ui-components pin is kept.
   **Still carrying the old name, all of it platform-side state**: the git-host repository, the
   CI repository id, the deployments application row, and the image repository
   `qits/qits-spa-cd`. A `--with-volumes` unwrap plus a rebootstrap is what recreates them under
   the new name; until that runs, they are the whole of what is left.

Resolved 2026-08-06: the **git-storage flip executed, and the file backend retired
the same day** (user: "the disk storage should be gone"). All 41 repositories imported
and three-check-verified; every path proven live: protection + both bypasses,
post-receive → CI, repository create/import over HTTP, history reads, the full release
train (SCMRelease → event run → SoftwareRelease), workspace container provisioning, a
service deploy, and qits-artifacts redeploying itself from its own DFS store — twice,
the second time as the dfs-only binary (`508e598`). The `qits-repositories` volume is
deleted (tarball: `~/qits-git-bares-final-2026-08-06.tar.gz`), the file-backend code
is gone, and `qits-local-up.sh` seeds over the wire (home `6843faf`). Full record in
git history: `git show 3d4382b:git-host-storage-unification-plan.md`.

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
