# Swarm migration campaign — handoff

## CAMPAIGN CLOSED 2026-08-13 (~13:30): swarm is the only orchestrator

Boot 6 — full boot on the docker-free mains — 70/70 in 14m16s, edge 200,
and the deployer SELF-UPDATED cleanly to deployments main (392c8b2, the
docker-deletion commit) with correct row settling. The docker path is
deleted (dockerhost/ gone, orchestrator key kept as a boot guard that
refuses anything but `swarm`; 315 tests). All six repos' mains pushed to
GitHub: cli-bootstrap 8103c1e, deployments 392c8b2, workspaces cf98b39,
projects 221a5ae, gateway c3dc174, edge 205ef30. The plan doc
(docker-swarm-migration-plan.md) is retired with the campaign; this file
is the record.

Boot 6's two warns were one rerun-semantics hole, now the top backlog
item: a volumes-KEPT re-bootstrap after unwrap keeps deployment rows
that claim ACTIVE while the services are gone, so replays of unchanged
repos' builds get dropped by tip-ordering (correct for its own purpose)
and an app can stay seed-served (qits-containers did). Salvage: force
env/dev one commit back with qits.no-ci, then forward — the fresh push
has a fresh build time and the tip accepts it. Durable fix candidates:
the sweep/observer marking rows whose service is gone, or the tip
consulting the daemon, not only rows.

Working tree: `/home/wohlben/code/qits-qits-swarm` (superproject worktree, every
submodule a linked worktree on branch `swarm-migration`). The live checkout at
`~/code/qits-qits` stays clean; nothing here ships until a proof bootstrap runs
from this tree.

Plan of record: `docker-swarm-migration-plan.md` (in both trees).
Decisions made by the user 2026-08-12:

- Phase −1 (containerized bootstrap CLI) happens first, before any swarm phase.
- Full campaign: prove, flip `orchestrator=swarm`, then delete
  `DockerDeploymentDriver`.
- Registry publish: accept `0.0.0.0:8081` (note it in the bootstrap summary; no
  firewall automation).

## In flight right now

- GREEN PING received 2026-08-12 ~22:15: daemon is ours. Peer's final state:
  restore-default boot zero-warn, cli-bootstrap main = 6103c72 (merged into
  swarm-migration as c630881, README conflict combined), qits-ci release
  2026.812.184140. Tag sweep re-run clean. Unwrap done (volumes kept).
- Overlay-proof bootstrap in progress (attempt 4). Attempts 1–3 taught:
  - Worktree wrappers need their git directories mounted into the payload:
    every .git here is a pointer file. Fixed in cli-bootstrap 24ddb90
    (linkedGitDirs resolves wrapper + all submodules through commondir;
    three submodules carry EMBEDDED .git dirs — edge, eventstream,
    oci-workspace). 301 tests green.
  - Fresh phase-4 clones lack the nested Quinoa webui submodules (their
    relative ../qits-spa-*.git URLs resolve nowhere local), so seed builds
    die on "No package.json in src/main/webui". The LIVE checkout's
    .qits-bootstrap-src clones have the webuis initialised from an earlier
    era and every green boot rode that state. Fix for this tree: copied the
    live src dir over (233M) and re-pointed 40 origins at the worktree's
    submodule paths. NOT a code fix — a truly cold machine would hit this
    too if a webui-carrying repo is seeded before the githost is up; noted
    as a standing observation, not this campaign's problem.
- Attempt-1/2 partial proof already banked: swarm preflight on an active
  swarm, qits-net created as attachable overlay, CLI self-attached (phase 2
  green three times).
- Attempt 4 died at phase 16: seed mirror "password authentication failed".
  ROOT CAUSE, verified in pg + pd_resource: the deployer's
  PgResourceProvisioner rotates an app role to a RANDOM password whenever the
  registry has no row (rows get wiped each boot by app re-registration), while
  the CLI's seed phase connects with the .qits-bootstrap.env value and
  ensureRoleIfMissing never alters. Handed-over cluster: role=rotated,
  env=original → every re-bootstrap seed of a pg-backed seed service is a
  latent landmine. Loopback pg_hba is `trust`, so testing a password needs the
  wire, not docker exec psql@localhost. Workaround applied before attempt 5:
  superuser ALTER of all 12 seed roles to the env values + DELETE of the
  stale pd_resource rows (deployer trusts rows unverified — a stale row would
  hand the successor a dead password mid-boot). Peer confirmed: their boots
  all ran --with-data-volumes (fresh cluster each time), ours was the FIRST
  volumes-kept re-bootstrap since rotation landed. DURABLE FIX LANDED:
  cli-bootstrap d7f908c — the postgres phase reads pd_resource once the
  server answers and seeds pg-backed services with what the rows say (the
  deployer's own two roles stay on the recorded env values). 303 tests
  green. The manual converge+clear pre-step is OBSOLETE from the next boot
  on — the flip proof needs nothing special.
- Attempt 5 then died anyway, and it taught the SECOND half of the lesson:
  deleting the pd_resource rows was WRONG. The deployer's kept pd_deployment
  rows make it RESURRECT old deployments mid-boot (restart-reconcile), and
  with the rows gone each resurrection took the rotate arm — rotating roles
  out from under the still-serving seed containers. qits_ci lost its DB,
  event consumption died, no CI run started, the deploy wait timed out at
  1h. The rows were never stale — they matched the roles; only my ALTER made
  them look stale. Rule: NEVER touch pd_resource by hand; d7f908c reads it.
  Post-failure state is consistent (roles rotated + rows recording them) —
  exactly what the fixed CLI consumes. Attempt 6 = plain rerun on d7f908c.

## Flip proof, first run (2026-08-13 early) — 70/70 with 11 warns, exit 1

The whole train RAN under swarm: seed as a stack, 11 pipeline deploys
converged as bare-alias services, edge 200. The 11 warns had ONE root
cause class: nothing removed a seed stack service when its successor
deployed. The twin holds the wire alias (DNS round-robins — a step's
ci-daemon registered with the CI instance that had not launched it and
exited 6: both CI FAILED warns) and any host-mode ports (artifacts,
githost, dns, mirror sat Pending on "port already in use" — the
no-terminal warns). Fixes landed on mains:

- deployments 13f36b6: SwarmDeploymentDriver reaps qits_<alias> before
  creating <alias> (after argv build, never for self); ownServiceName
  replaces isSelf so a deployer still running as the SEED stack service
  self-updates qits_dev-qits-deployments in place instead of creating a
  second deployer. 349 green.
- cli-bootstrap fac61b9: seedPlan recognises swarm-deployed apps by a
  service under the bare wire alias (swarm tasks are not qits-pd-named
  containers), and only ever sweeps the qits_ twin — the bare-alias
  service is the deployer's own. 318 green.

The second flip-proof boot then died at phase 15: postgres PANIC,
"could not locate a valid checkpoint record" — the first boot's
un-reaped postgres twin meant seed AND deployed postgres ran as TWO
WRITERS on qits-oci-postgresql-data, corrupting the WAL. (The very
hazard phase 15's own comment names.) Rather than trust a resetwal'd
cluster two servers wrote to, the volume was reset: unwrap
--with-data-volumes (config volumes kept, all tags mirrored locally +
GitHub, the boot re-pushes repos and tags). Third flip-proof boot
running on fresh data volumes. Remaining to verify: zero warns,
self-update + forced rollback + DNS timing checks, then docker-driver
deletion.

## Third flip boot — pg-cutover gap fallout + live salvage (2026-08-13 morning)

The deployer's cutover of qits-oci-postgresql itself opens a ~90s DB gap
that PatientPgDriver's 14s hold cannot bridge. Everything that touched
postgres in that window broke, three distinct DEFECTS, all real:

1. qits-githost ACKED the idp push while its ref writes AND the
   SCMPublishCommit outbox write died with the gap (outbox lives in the
   eventstream datasource — a separate database, so "inside the push's
   own transaction" does not hold across that boundary). Repo held
   neither ref afterwards; "[new branch]" on the re-push proved it.
2. The deployer's resource provisioning generated a fresh password,
   handed it to the successor service, and THEN lost both the ALTER
   ROLE and the pd_resource row to the gap — deployed idp crashlooped
   on a password no role ever had (service env 6863…, role still env
   b46e…, registry row absent).
3. With idp down, the machine gate failed platform-wide: every step
   container start 401'd at qits-containers, so every subsequent CI run
   died at step 1 (idp + stt phases burned this way).

Salvage, in order: POST /events/api/events replay for idp (CI refused
"no longer holds commit" — which exposed defect 1), re-push of idp
main + environment/dev (both "[new branch]"), docker service update of
qits-platform-idp's QITS_RESOURCE_DB_PASSWORD to the role's real value
(idp 1/1 + health 200, gate restored), then an events replay for
qits-stt. Boot continued green from phase 56 on. The twin-reap fix
itself is PROVEN: postgres cutover 10s, seed twins removed at each
deploy, no port Pending, no alias duality anywhere this boot.

Backlog candidates (not this campaign): hold provisioning while the
deployer cuts over the database host itself; make the githost push ack
wait on the ref+outbox writes; events-door replay is the working
recipe for a lost announcement (payload shape = copy of a stored
sibling event).

## Boots 3+4 post-mortem addenda (2026-08-13 mid-morning)

- CLI 8103c1e: platformContainerAtSha (and alreadyLive through it) matched
  only qits-pd- names and tripped on swarm's @digest image suffix — dns sat
  deployed-and-healthy for 44 min while the wait stared past it. Boot 3 was
  killed deliberately once this was fixed (letting it run = 1h burn each on
  mirror + edge).
- The seed CI's agroal pool never recovers from a pg-cutover gap (pool
  starved on "Acquisition timeout" an hour later) — `docker service update
  --force qits_dev-qits-ci` is the recipe. Backlog: pool self-healing.
- deployments 77d1cf6: reapSeedTwin now DRAINS the twin's tasks (poll by
  swarm service label, ≤10s) before the successor is created. service rm
  returns while the task is stopping; ports self-serialize, VOLUMES do not
  — postgres met its successor on one data volume for a few seconds and
  the WAL died again ("could not locate a valid checkpoint record", second
  time). Data volumes wiped again; boot 5 runs full on the fixed mains.
- Salvage door inventory grew: POST /events/api/events (no machine gate) to
  replay a lost SCMPublishCommit; docker service update --env-add to fix an
  orphaned credential; service update --force to restart a wedged seed task.

## BOOT 5 — THE FLIP PROOF (2026-08-13 ~10:35): 70/70 in 22m13s, ONE warn

All 17 applications deployed as swarm services 1/1 at their main shas,
edge 200. The deployer SELF-UPDATED through the manager: its stack-named
service qits_dev-qits-deployments ended on the pipeline image at
deployments main's exact sha. The single warn was bookkeeping: the
successor's sweep asked runningImage under the bare alias while the
deployer lives under the stack name — fixed (deployments cb94bcf,
runningImage falls back to qits_<name>; 350 green). Sweep corrections
still announce no events, by design.

Checklist verifications, all done:
- Forced rollback: docs updated to a bogus image with the driver's own
  flags → rollback_completed, original image restored, 1/1 — and a
  0.5s-interval probe through the edge saw 36/36 HTTP 200, zero slow
  requests. Start-first + manager rollback = literal zero downtime.
- Deploy events: 17 Queued / 17 Started / 16 Active in qits-events (the
  17th Active was the mis-settled self-update row, fixed above).
- CI steps/workspaces/agents on the overlay: every pipeline build of the
  proof boots ran its step containers through qits-containers on
  qits-net; workspaces + projects deployed healthy.
- DNS behavior: no request through the front door hung or slowed during
  a full failed-update + rollback cycle.

Remaining: docker-path deletion (agent in flight), final boot on the
cleaned mains, GitHub pushes, wrapper→platform-githost catalog push.

## Status vocabulary refinement (2026-08-13 afternoon)

Deployment STATUS tells the truth now: ROLLED_BACK (manager restored the
predecessor, service kept serving), SUPERSEDED (interrupted row overtaken),
GONE (observer-confirmed absence, recoverable), FAILED narrowed to "nothing
is known to serve". CLI learned the words first (424d62f), deployer writes
them (ea9a18f), SPA renders human labels (spa 5485d6c/39c678a, bump 49b27ce).
The verification flushed two more driver defects, both fixed and shipped:
observe() was blind to the stack-named service (64341b2 — a healthy
self-updated deployer got observation-FAILED), and awaitConverged trusted
the FIRST UpdateStatus poll, reading the PREVIOUS update's terminal state
or the predecessor's Running task as instant convergence (ecdaa86 — now
matches UpdateStatus.StartedAt against the issue instant, 5s skew; NB
docker --format prints Go time, not RFC3339). Live proof: a broken-gate
docs deploy recorded ROLLED_BACK with swarm's wording while 237/237 edge
probes answered 200; the revert went ACTIVE in 37s; the badge renders
amber in the SPA.

## Phase-7 flip checklist (collect here)

- Merge swarm-stack into swarm-migration after the overlay proof.
- Flip qits.platform.deployments.orchestrator default to swarm; delete
  DockerDeploymentDriver/DockerCli + their tests after the flip proof.
- Verify the CLI's deploy-phase checks (platformContainerAtSha, alreadyLive,
  DeployLogStream — still `docker ps`-shaped) work against swarm-deployed
  services: tasks are containers and carry --container-label, but names are
  <svc>.<slot>.<taskid>. Phase 5 left them container-shaped on purpose.
- During the flip proof: empirically check the negative-DNS fix under native
  (curl the front door during a rolling start; recovery must be instant once
  the task is healthy, not ~10s), and that a starting service's requests fail
  fast (~5s) instead of hanging 60s.
- qits-gateway and qits-platform-edge JOIN the flip merge set (front-door
  fixes on their swarm-migration branches).
- Final proof includes: deployer self-update via service update, a forced
  rollback (unhealthy successor), CI step containers + a workspace + an agent
  container on the overlay, edge 200, deploy events visible in qits-events.
- Merges to main: cli-bootstrap, deployments, workspaces, projects (+ wrapper
  superproject merge). Push wrapper to platform githost afterwards (catalog).

## DAEMON LOCK — EXTENDED (2026-08-12 ~20:45). Successor: READ THIS FIRST.

Stage C ended 69 ok + 1 warn (exit 1): REAL defect found — restore boot's
seed builds from main while the tag-built binary refused the main-applied
Flyway V3 (qits-ci); peer salvaged live via DB surgery + manual-door replay.
Peer is NOW: (1) releasing qits-ci with V3 through the workspaces door,
(2) landing a cli-bootstrap fix (restore-mode seeds build from the RELEASE
TAG, not main), (3) rerunning stage C for a zero-warn proof. ETA 60-90 min
from ~20:45. RULES: do NOT unwrap or bootstrap on a timeout; silence =
still locked; wait for the peer session's explicit green ping
(container-orchestration-impl). Before our proof run: merge the CLI's main
into swarm-migration AGAIN (their restore-seed fix must not diverge from
our branch).

## DAEMON LOCK (2026-08-12 evening) — stages A+B GREEN, C in flight

Peer confirmation: stage A green (seven tag-triggered publisher replays, zero
SoftwareRelease, zero bump runs); stage B released all ten tagless
deployables (idp, docs, deployments gained their first ci-event-release.yml);
all seventeen deployables' mains+tags synced locally and to GitHub. So the
deploy-lifecycle events (deployments b1058ae) are now RELEASED, not just
deployed. Stage C = first restore-default boot, running; peer pings when
green. Our proof run afterwards ships mains again — expected sha delta vs
released identity.

The container-orchestration-impl session is running three stages against the
live platform: (A) ship-mains rebootstrap proving today's replay semantics,
(B) release the ten tagless deployables one at a time, (C) first
restore-default rebootstrap. NO docker-daemon activity from this campaign
until that session messages completion. Their stage B ends with a full fleet
tag sync, so our later unwrap is tag-safe. Their note: restore is now the
DEFAULT boot; pass QITS_SHIP_MAINS=1 for every proof run here.

Also: the CLI's main was merged into swarm-migration (aa42602, 268 tests
green) — brings tag replay + the ship-mains flag; without it the replay
phases fail against mains that carry SCMPublishTag recipes.

- Front-door fixes done (gateway f707ca1, 146 green; edge 0917d26, 54 green):
  -Dnetworkaddress.cache.negative.ttl=0 in both runtime entrypoints;
  qits.gateway/edge.connect-timeout-ms property, default 5000, on the proxy
  clients (idle timeout 0 untouched). §3.4 answered: NXDOMAIN and
  connection-refused both already 502 in both services (vertx-http-proxy
  single recover path, verified from bytecode).
- Phase 5 done (cli-bootstrap 2871a62 on swarm-stack, 304 green): stack file
  (no root name, deploy blocks, restart_policy any/5s, no update_config —
  swarm default IS stop-first and start-first is wrong for every seed
  service); postgres publishes NOTHING (QITS_PG_PORT retired); DOCKER_GID via
  user "1001:<gid>" (group_add REFUSED by stack deploy, measured); edge ACME
  9000 unpublished, issue-certificate now sent from qits-net; seedStackUp →
  stack deploy with deploy/managed/stale plan (stale services service-rm'd);
  partial deploys via a generated partial stack file, no --prune; unwrap
  gained stack-rm + service reap; Docker.lines() bug fixed (error text was
  parsed as names). Rendered files pass docker stack config clean.
- Phase 6 done (deployments e699842, 259 green): referee machinery deleted
  (handoff/buildHandoffArgv/socketGid/arbitration script); docker path now
  REFUSES self-update before touching anything (bootstrap starts the deployer
  directly; the pre-flip release rides the old deployer that still has the
  referee); sweep settles STARTING rows by runningImage() sha comparison
  (image primary, swarm UpdateStatus as detail only). Sweep/observer
  corrections deliberately announce NO deploy events (b1058ae decision,
  unchanged).
- Phase 4 done: deployments 58aa4dc (254 green), cli-bootstrap faaf0fb (257
  green). extras.<app>.mounts/publishes/groups/env grammar owned by
  ServiceExtras.java; fail-loud on garbage; postgres publish gone from
  extras; artifacts/mirror/githost widened to 0.0.0.0; edge's ACME 9000
  publish REFUSES under swarm rather than widen (deliberate).

## Done

- Phase 3 (deployments 683eb04 + 9886374 + ae1836b, 249 tests green):
  DeploymentDriver reshaped to nameOf/apply/awaitConverged (+pull, observe,
  reap, networks); docker cutover choreography moved INTO the docker driver
  over a new DockerHost CLI seam (old flow tests now drive the real
  choreography); service/swarmhost renders service create/update with
  --update-order/--update-monitor/--update-failure-action rollback;
  verdicts completed→ACTIVE, rollback_completed/paused/timeout→FAILED;
  orchestrator=docker default; update_order in deployments.yml (deployer
  itself = stop-first). Deploy events fire at the same four transitions on
  both paths. HAZARD noted in repo: the deployer's own yml update_order key
  must not reach a deployed sha before the parser that reads it.

- Phase 2 (workspaces 99721ed, projects 1874860, both repos verify green):
  missing qits-net now created as attachable overlay (bridge fallback + warn on
  a non-swarm daemon); existing networks untouched whatever the driver;
  qits-ci and daemons/ have no network-create sites (ci's moved to
  qits-containers, which only inspects — deliberately).
- Worktree note: nested Quinoa webui submodules are checked out now for ALL
  repos (gateway needed protocol.file.allow=always from the live checkout's
  module; docs needed a fetch from the live checkout — its gitlink commit is
  local-only). A fresh worktree needs this again.
- Phase 0+1 (cli-bootstrap 179a198, 255 tests green): preflight swarm-inits
  when inactive, refuses pending/locked/worker/unknown; qits-net created as
  attachable overlay; existing bridge = hard collision naming `unwrap` as the
  fix; unwrap network removal retries 6×500ms. serviceNames/stackDeploy
  helpers deferred to phase 5 (would be callerless + untested now).
  NOTE for the proof run: the live qits-net is a bridge — first bootstrap on
  this branch stops at the collision until unwrap removes it. That is the
  intended re-bootstrap path.

- Phase −1 was ALREADY SHIPPED and proven: the containerized CLI merged to the
  CLI's main 2026-08-09 (62b105c→3eebc6f); every green bootstrap since 08-10
  ran through it. This campaign added only 1d1bc55 (buildx preflight + two
  stale comments). qits-local-up.sh needed no change.
- User decision 2026-08-12: the postgres publish is REMOVED in phase 5.
  Postgres publishes nothing; operator access is `docker exec` or a throwaway
  psql container on qits-net. (QITS_PG_PORT knob and its README row retire
  with it.)

## Proof-run playbook (phase 0+1 proof; recon findings 2026-08-12 evening)

LOAD-BEARING: a bootstrap ships each submodule's local MAIN, never the
checked-out branch (Git.java:28, SeedPhases sources()). Only the CLI's own
working tree ships (it becomes the binary). So this proof covers phase −1/0/1
only; phases 2/3/4 ship at the phase-7 flip via merges to main.

Before the run:
1. Wait for phase 4 agent, then merge the CLI's `main` INTO `swarm-migration`
   in cli/qits-cli-bootstrap (brings 28c4e77 tag-replay + 669aad2 restore
   default). Without it, release replay fails at phase 44 (mains carry WP1a
   SCMPublishTag recipes; the old CLI fabricates SCMRelease). Then run with
   --ship-mains (restore would warn-exit-1: several deployables have no tag).
2. Re-run the tag sweep (all tags currently on the githost are mirrored
   locally as of this evening; the 08-11 stamps were already erased by the
   16:11 --with-data-volumes re-bootstrap, before this campaign):
   `git -C <sub> fetch --no-recurse-submodules --tags
    http://localhost:8083/git/<name> 'refs/tags/*:refs/tags/*'`
3. .env and .qits-bootstrap.env are COPIED into the worktree root already.
4. Unwrap from the LIVE checkout (it has docker-compose.qits.yml + state),
   volumes kept: `./qits-local-up.sh unwrap` after `--dry-run`.
5. Boot from the worktree:
   `QITS_RELEASE_TIMEOUT=900 ./qits-local-up.sh --ship-mains`
6. Green = exit 0, `done: ~70 phases`, ~17 qits-pd-* healthy, edge 200.
   Log: cli/qits-cli-bootstrap/qits-bootstrap-cli.log. Budget 30–60 min.
   qits-net bridge collision cannot happen if unwrap ran (phase 2 fails in
   seconds if it does — rerun unwrap).

## Order of proof bootstraps

1. Containerized CLI, everything else unchanged (phase −1).
2. Overlays on docker-run code (phase 0).
3. Swarm driver flipped on (phase 7), incl. deployer self-update + rollback.
