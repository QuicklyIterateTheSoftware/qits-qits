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

- Phase 4: structured run-args (deployments + cli-bootstrap) — Opus subagent.
- Recon for the proof re-bootstrap (what ships, restore-vs-mains flag, .env,
  tag-sync-before-unwrap) — Explore subagent, read-only.

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
