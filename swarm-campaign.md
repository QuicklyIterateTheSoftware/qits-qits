# Swarm migration campaign — handoff

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
